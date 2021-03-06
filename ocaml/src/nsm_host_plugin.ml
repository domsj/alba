(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open Lwt.Infix
open Registry
open! Prelude
module Arakoon_update = Update
open Nsm_model
open Plugin_extra
open Nsm_host_protocol

module Keys = struct
  let nsm_host_version = "/nsm_host_version/"

  let next_msg = "/nsm_host_next_msg/"

  let namespace_info_prefix = "/nsms/"
  let namespace_info namespace_id =
    namespace_info_prefix ^ (serialize x_int64_to namespace_id)

  let namespace_content_prefix = "/nsm/"
  let namespace_content namespace_id =
    namespace_content_prefix ^ (serialize x_int64_to namespace_id)
end

let deliver_msgs_user_function_name = "nsm_host_user_function"

let transform_updates namespace_id =
  let open Arakoon_update in

  let prefix = Keys.namespace_content namespace_id in
  let with_prefix k = prefix ^ k in

  List.map
    (function
      | Key_value_store.Update.Set (k, None) ->
        (* TODO: arakoon needs a delete which doesn't throw *)
        Update.Replace (with_prefix k, None)
      | Key_value_store.Update.Set (k, Some v) ->
        Update.Set (with_prefix k,v)
      | Key_value_store.Update.Assert (k,vo) ->
        Update.Assert (with_prefix k,vo)
      | Key_value_store.Update.Transform(k,t) ->
        begin
          match t with
          | Key_value_store.Update.ADD x ->
            Arith64.make_update (with_prefix k)
                                Arith64.PLUS_EQ x
                                ~clear_if_zero:true
        end
    )

let get_next_msg_id db =
  let expected_id_s = db # get Keys.next_msg in
  let expected_id = match expected_id_s with
    | None -> 0L
    | Some s -> deserialize x_int64_from s in
  expected_id_s, expected_id

let handle_msg db =
  let open Arakoon_update in
  let open Protocol in
  let open Message in
  function
  | CreateNamespace (namespace_name, namespace_id) ->
     let key = Keys.namespace_info namespace_id in
     [ Update.Assert (key, None);
       Update.Set (key,
                   serialize
                     namespace_state_to_buf
                     (Active namespace_name)); ]
  | DeleteNamespace namespace_id ->
     let key = Keys.namespace_info namespace_id in
     [ Update.Replace (key, None); ]
  | RecoverNamespace (namespace_name, namespace_id) ->
     let key = Keys.namespace_info namespace_id in
     [ Update.Assert (key, None);
       Update.Set (key,
                   serialize
                     namespace_state_to_buf
                     (Recovering namespace_name)); ]
  | NamespaceMsg (namespace_id, msg) ->
     if not (db # exists (Keys.namespace_info namespace_id))
     then []
     else begin
         let module KV = WrapReadUserDb(
                             struct
                               let db = db
                               let prefix = Keys.namespace_content namespace_id
                             end) in
         let module NSM = NamespaceManager(struct let namespace_id = namespace_id end)(KV) in

         let open Namespace_message in
         let upds = match msg with
           | LinkOsd (osd_id, osd_info) ->
              NSM.link_osd db osd_id osd_info
           | UnlinkOsd osd_id ->
              NSM.unlink_osd db osd_id
         in
         transform_updates namespace_id upds
       end

let deliver_msgs (db : user_db) msgs =
  let _, first_msg_id = get_next_msg_id db in
  List.iter
    (fun (msg_id, msg) ->
     if msg_id >= first_msg_id
     then
       begin
         let upds = handle_msg (db :> read_user_db) msg in
         List.iter
           (apply_update db)
           upds;
         db # put
            Keys.next_msg
            (Some (serialize
                     x_int64_to
                     (Int64.succ msg_id)))
       end)
    msgs


let rec get_updates_res : type i o. read_user_db ->
                               (i, o) Protocol.update ->
                               i ->
                               (o * Arakoon_update.Update.t list) Lwt.t =
  fun db ->
  let open Protocol in
  let open Arakoon_update in
  function
  | CleanupForNamespace -> fun namespace_id ->
    let prefix = Keys.namespace_content namespace_id in
    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = prefix
      end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    let (cnt, keys), _ = EKV.range db ~first:"" ~finc:true ~last:None ~max:1000 ~reverse:false in
    Lwt.return (cnt, (List.map (fun k -> Update.Replace (prefix ^ k, None)) keys))
  | DeliverMsg -> fun (msg, id) ->
    let expected_id_s, expected_id = get_next_msg_id db in
    if id <> expected_id
    then Lwt.return ((), [])
    else
      begin
        let upds = handle_msg db msg in
        let bump_next_msg =
          [ Update.Assert (Keys.next_msg, expected_id_s);
            Update.Set (Keys.next_msg, (serialize x_int64_to (Int64.succ expected_id))); ]
        in
        Lwt.return ((), List.append bump_next_msg upds)
      end
  | DeliverMsgs ->
     fun msgs ->
     Lwt.return
       ((),
        [ Update.UserFunction
            (deliver_msgs_user_function_name,
             Some (serialize
                     (Llio.list_to
                        (Llio.pair_to
                           x_int64_to
                           Message.to_buffer))
                     msgs)); ])
  | NsmUpdate tag -> fun (namespace_id, req) ->
    if not (db # exists (Keys.namespace_info namespace_id))
    then Err.(failwith ~payload:(Int64.to_string namespace_id) Namespace_id_not_found);

    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = Keys.namespace_content namespace_id
      end) in
    let module NSM = NamespaceManager(struct let namespace_id = namespace_id end)(KV) in
    let open Nsm_protocol.Protocol in
    let get_updates_res : type req res.
      (req, res) update -> req -> (Key_value_store.Update.t list * res) =
      function
      | DisableGcEpoch -> fun gc_epoch ->
        NSM.disable_gc_epoch db gc_epoch, ()
      | EnableGcEpoch -> fun gc_epoch ->
        NSM.enable_new_gc_epoch db gc_epoch, ()
      | PutObject -> fun (overwrite, manifest, fragment_gc_epochs) ->
        NSM.put_object db overwrite manifest fragment_gc_epochs
      | DeleteObject -> fun (overwrite, object_name) ->
        NSM.delete_object db object_name overwrite
      | UpdateObject -> fun (object_name, object_id, new_fragments, gc_epoch, version_id) ->
        NSM.update_manifest db object_name object_id new_fragments gc_epoch version_id, ()
      | MarkKeysDeleted -> fun device_keys ->
        NSM.mark_keys_deleted db device_keys, ()
      | CleanupOsdKeysToBeDeleted -> fun osd_id ->
        NSM.cleanup_osd_keys_to_be_deleted db osd_id
      | ApplySequence ->
         fun (asserts, updates) ->
         NSM.apply_sequence db asserts updates
      | UpdatePreset ->
         fun (preset, version) ->
         NSM.update_preset db preset version
      | UpdateObject2 ->
         fun (object_name, object_id, updates, gc_epoch, version_id) ->
         NSM.update_manifest2 db
                              object_name object_id updates
                              gc_epoch version_id
         , ()
      | UpdateObject3 ->
         fun (object_name, object_id, updates, gc_epoch, version_id) ->
         NSM.update_manifest2 db
                              object_name object_id updates
                              gc_epoch version_id
         , ()
    in
    let upds, res = get_updates_res tag req in
    let arakoon_upds = transform_updates namespace_id upds in
    Lwt.return (res, arakoon_upds)
  | NsmsUpdate tag ->
     fun reqs ->
     Lwt_list.map_s
       (fun req ->
         Lwt.catch
           (fun () ->
             get_updates_res db (NsmUpdate tag) req >>= fun (res, upds) ->
             Lwt.return (upds, Result.Ok res))
           (function
            | Nsm_model.Err.Nsm_exn (err, _) ->
               Lwt.return ([], Result.Error err)
            | exn -> Lwt.fail exn
           )
       )
       reqs >>= fun r ->
     let upds, res = List.split r in
     Lwt.return (res, List.flatten upds)

let statistics = Protocol.NSMHStatistics.make ()

let maybe_activate_reporting =
  let is_active = ref false in
  fun () ->
  begin
    if !is_active
    then ()
    else
      let rec inner () =
        Lwt_unix.sleep 60. >>= fun() ->
        Lwt_log.info_f
          "stats:\n%s%!"
          (Protocol.NSMHStatistics.show statistics)
        >>= fun () ->
        inner ()
      in
      is_active := true;
      Lwt_log.ign_info "activated nsm host statistics reporting";
      Lwt.ignore_result (inner ())
  end


let handle_query : type i o. read_user_db ->
                        Nsm_protocol.Session.t ->
                        (i, o) Nsm_host_protocol.Protocol.query -> i -> o
  =
  fun db session tag req ->
  let open Nsm_host_protocol.Protocol in
  let nsm_query tag namespace_id req =
    let prefix = Keys.namespace_content namespace_id in
    let module KV = WrapReadUserDb(
                        struct
                          let db = db
                          let prefix = prefix
                        end) in
    let module NSM = NamespaceManager(struct let namespace_id = namespace_id end)(KV) in
    let open Nsm_protocol.Protocol in
    let exec_query : type req res.
                          (req, res) Nsm_protocol.Protocol.query -> req -> res =
      function
      | GetObjectManifestByName ->
         fun object_name ->
         NSM.get_object_manifest_by_name db object_name
      | GetObjectManifestsByName ->
         fun object_names ->
         List.map
           (NSM.get_object_manifest_by_name db)
           object_names
      | GetObjectManifestById ->
         fun object_id -> begin
             try
               let manifest, _ = NSM.get_object_manifest_by_id db object_id in
               Some manifest
             with
             | Err.Nsm_exn (Err.Object_not_found, _) -> None
             | exn -> raise exn
           end
      | ListObjects ->
         fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
         NSM.list_objects
           db
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
      | ListObjectsById ->
         fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
         NSM.list_objects_by_id
           db
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
      | ListDeviceKeysToBeDeleted ->
         fun (device_id, { RangeQueryArgs.first; finc; last; max; reverse; }) ->
         NSM.list_device_keys_to_be_deleted db device_id
                                            ~first ~finc ~last
                                            ~max:(cap_max ~max ())
                                            ~reverse
      | ListObjectsByOsd ->
         fun (device_id, { RangeQueryArgs.first; finc; last; max; reverse; }) ->
         NSM.list_device_objects
           db device_id
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
      | MultiExists ->
         fun object_names ->
         NSM.multi_exists db object_names
      | GetGcEpochs -> fun () -> snd (NSM.get_gc_epochs db)
      | GetStats -> fun () -> NSM.get_stats db
      | ListObjectsByPolicy ->
         fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
         NSM.list_objects_by_policy
           db
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
      | ListActiveOsds ->
         fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
         NSM.list_active_osds
           db
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
    in
    if not (db # exists (Keys.namespace_info namespace_id))
    then Err.(failwith ~payload:(Int64.to_string namespace_id) Namespace_id_not_found)
    else exec_query tag req
  in
  match tag with
  | ListNsms ->
    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = Keys.namespace_info_prefix
      end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    let (cnt, nsms), _has_more =
      EKV.map_range
        db
        ~first:"" ~finc:true
        ~last:None
        ~max:(-1) ~reverse:false
        (fun cur key ->
           let namespace_id = deserialize x_int64_from key in
           let state = deserialize namespace_state_from_buf (KV.cur_get_value cur) in
           (namespace_id, state))
    in
    cnt, nsms
  | GetVersion -> Alba_version.summary
  | NSMHStatistics ->
     NSMHStatistics.snapshot statistics req
  | NsmQuery tag ->
     let namespace_id, req = req in
     nsm_query tag namespace_id req
  | NsmsQuery tag ->
     List.map
       (fun (namespace_id, req) ->
        try Result.Ok (nsm_query tag namespace_id req)
        with Nsm_model.Err.Nsm_exn (err, _) -> Result.Error err)
       req
  | UpdateSession ->
     begin
       let r =
         List.fold_left
         (fun acc (k,vo) ->
           begin
             match k with
             | "manifest_ser" ->
                begin
                  match vo with
                  | None -> acc
                  | Some v ->
                     let wanted_version = deserialize Llio.int8_from v in
                     let new_version = min 2 wanted_version in
                     let v' = serialize Llio.int8_to new_version in
                     let () =
                       Nsm_protocol.Session.set_manifest_ser session new_version in
                     (k, v') :: acc
                end
             | _ -> acc
           end
         ) [] req
       in
       List.rev r
     end

let nsm_host_user_hook : HookRegistry.h = fun (ic, oc, _cid) db backend ->

  (* ensure the current version is stored in the database *)
  let get_version () =
    Option.map
      (fun vs -> deserialize Llio.int32_from vs)
      (db # get Keys.nsm_host_version)
  in
  begin match get_version () with
    | None ->
      backend # push_update
        (Arakoon_update.Update.TestAndSet
           (Keys.nsm_host_version,
            None,
            Some (serialize Llio.int32_to 0l))) >>= fun _ ->
      Lwt.return ()
    | Some _ ->
      Lwt.return ()
  end >>= fun () ->
  let get_version () = Option.get_some (get_version ()) in

  let () = maybe_activate_reporting () in

  (* this is the only supported version for now
     we want to ensure here that no old version
     can work on new data *)
  let check_version () =
    0l = get_version () in
  let assert_version_update =
    Arakoon_update.Update.Assert
      (Keys.nsm_host_version,
       Some (serialize Llio.int32_to 0l)) in

  let write_response_ok serializer res =
    Lwt.return
      (fun () ->
        let s =
          serialize
            (Llio.pair_to Llio.int32_to serializer)
            (0l, res) in
        Plugin_helper.debug_f
          "NSM host: Writing ok response (4+%i bytes)"
          (String.length s);
        Lwt_extra2.llio_output_and_flush oc s)
  in
  let write_response_error payload err =
    Lwt.return
      (fun () ->
        Plugin_helper.debug_f "NSM host: Writing error response %s" (Err.show err);
        let s =
          serialize
            (Llio.pair_to
               Llio.int_to
               Llio.string_to)
            (Err.err2int err, payload) in
        Lwt_extra2.llio_output_and_flush oc s)
  in


  let do_one session tag req_buf =
    let tag_name = (Protocol.tag_to_name tag) in
    Plugin_helper.debug_f "NSM host: Got tag %s" tag_name;
    let open Protocol in
    match (tag_to_command tag) with
    | Wrap_q r ->
      let consistency = Consistency.from_buffer req_buf in
      let req = read_query_i r req_buf in
      let read_allowed =
        try
          backend # read_allowed consistency;
          true
        with _ -> false
      in
      if not (check_version ())
      then write_response_error "" Err.Old_plugin_version
      else if read_allowed
      then
        Lwt.catch
          (fun () ->
             let res = handle_query db session r req in
             let res_serializer = write_query_o session r in
             write_response_ok res_serializer res)
          (function
           | Err.Nsm_exn (err, payload) ->
              write_response_error payload err
            | exn ->
              let msg = Printexc.to_string exn in
              Plugin_helper.info_f "unknown exception : %s" msg;
              write_response_error msg Err.Unknown)
      else
        write_response_error "" Err.Inconsistent_read
    | Wrap_u u ->
      let req = read_update_i u req_buf in
      let rec try_update = function
        | 5 -> Lwt.fail_with
                 (Printf.sprintf
                    "NSM host: too many retries for operation %s"
                    tag_name)
        | cnt ->
          Lwt.catch
            (fun () ->
               get_updates_res db u req >>= fun (res, upds) ->
               backend # push_update
                 (Arakoon_update.Update.Sequence
                    (assert_version_update :: upds)) >>= fun _ ->
               Lwt.return (`Succes res))
               (function
                 | Protocol_common.XException (rc, key) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
                   Plugin_helper.info_f "NSM: Assert failed %S" key;
                   (* TODO if the optimistic concurrency fails too many times then
                      automatically turn it into a user function? *)
                   Lwt.return `Retry
                 | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_NOT_MASTER ->
                   Err.failwith Err.Not_master
                 | exn -> Lwt.return (`Fail exn))
               >>= function
               | `Succes res -> Lwt.return res
               | `Retry -> try_update (cnt + 1)
               | `Fail exn -> Lwt.fail exn in
      Lwt.catch
        (fun () ->
           if not (check_version ())
           then write_response_error "" Err.Old_plugin_version
           else begin
             try_update 0 >>= fun res ->
             let serializer = write_update_o session u in
             write_response_ok serializer res
           end)
        (function
         | End_of_file as exn ->
            Lwt.fail exn
         | Err.Nsm_exn (err, payload) ->
            write_response_error payload err
         | exn ->
            let msg = Printexc.to_string exn in
            Plugin_helper.info_f "unknown exception : %s" msg;
            write_response_error msg Err.Unknown
        )
  in
  let rec inner (session:Nsm_protocol.Session.t) =
    Plugin_helper.debug_f "NSM host: Waiting for new request";
    Llio.input_string ic >>= fun req_s ->
    let req_buf = Llio.make_buffer req_s 0 in
    let tag = Llio.int32_from req_buf in

    Lwt.catch
      (fun () ->
        with_timing_lwt
          (fun () -> do_one session tag req_buf) >>= fun (delta,f_write_response) ->
        f_write_response () >>= fun () ->
        Protocol.NSMHStatistics.new_delta statistics tag delta;
        Lwt.return_unit
      )
      (function
       | Err.Nsm_exn (Err.Unknown_operation as err, payload) ->
          write_response_error payload err >>= fun f_write_response ->
          f_write_response ()
       | exn -> Lwt.fail exn)
    >>= fun () ->

    inner session
  in
  let session = Nsm_protocol.Session.make () in

  (* confirm the user hook could be found
   * (after we've done any operations that might potentially fail)
   *)
  Llio.output_int32 oc 0l >>= fun () ->

  inner session



let () = Registry.register
           deliver_msgs_user_function_name
           (fun user_db ->
            function
            | None -> assert false
            | Some req_s ->
               let open Protocol in
               let msgs = deserialize
                            (Llio.list_from
                               (Llio.pair_from
                                  x_int64_from
                                  Message.from_buffer))
                            req_s
               in
               deliver_msgs user_db msgs;
               None)
let () = HookRegistry.register "nsm_host" nsm_host_user_hook
let () = Arith64.register()
(* TODO make sure all ints are actually unsigned
   (use uint package or just add some asserts where needed...) *)
(* TODO add deriving.show to arakoon and slash some code
   (this requires first replacing the logging macro there
   https://github.com/whitequark/lwt/blob/master/ppx/ppx_lwt_ex.ml#L249 ) *)
(* TODO allow modelling a lost fragment and schedule it for repair
   e.g. because of partial disk failure/corruption *)

let () =
  let open Alba_version in
  Lwt_log.ign_info_f
    "nsm_host_plugin (%i,%i,%i) git_version:%s"
    major minor patch git_revision
