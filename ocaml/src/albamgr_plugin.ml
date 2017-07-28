(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Registry
open Lwt.Infix
open Albamgr_protocol
open Plugin_extra
open Update



module Keys = struct

  let alba_id = "/alba/id"
  let albamgr_version = "/alba/version"
  let client_config = "/alba/client_config"

  let lease ~lease_name = "/alba/lease/" ^ lease_name

  let participants_prefix = "/alba/participants/"
  let participants ~prefix ~name = participants_prefix ^ prefix ^ name

  let progress name = "/alba/progress/" ^ name
  let have_job_name_index = "/alba/have_job_name_index"

  let maintenance_config = "/alba/maintenance_config"

  module Nsm_host = struct
    (* this maps to some info about the nsmhost *)
    let info_prefix = "/alba/nsm_host/info/"
    let info nsm_host_id = info_prefix ^ nsm_host_id
    let info_next_prefix = Key_value_store.next_prefix info_prefix
    let info_extract_nsm_host_id =
      let prefix_len = String.length info_prefix in
      fun key -> Str.string_after key prefix_len

    let msg_log_prefix = "/alba/nsm_host/msg_log/"

    let count_prefix = "/alba/nsm_host/count/"
    let count nsm_host_id = count_prefix ^ nsm_host_id
  end

  module Osd = struct
    (* map
       long_id -> Osd.ClaimInfo.t, Osd.t
       osd_id -> long_id
    *)

    (* this maps to some info about the device such as hostname, port, type (kinetic, other), in_use/decomissioned ... *)
    let info_prefix = "/alba/osds/info/"
    let info ~long_id = info_prefix ^ long_id
    let info_next_prefix = Key_value_store.next_prefix info_prefix
    let info_extract_long_id =
      let prefix_len = String.length info_prefix in
      fun key -> Str.string_after key prefix_len

    let osd_id_to_long_id_prefix = "/alba/osd/byosd_id/"
    let osd_id_to_long_id_next_prefix = Key_value_store.next_prefix osd_id_to_long_id_prefix
    let osd_id_to_long_id ~osd_id = "/alba/osd/byosd_id/" ^ (serialize x_int64_be_to osd_id)
    let osd_id_to_long_id_extract_osd_id =
      let prefix_len = String.length osd_id_to_long_id_prefix in
      fun key -> x_int64_be_from (Llio.make_buffer key prefix_len)

    let next_id = "/alba/osd/next_id"

    let msg_log_prefix = "/alba/osds/msg_log/"

    let namespaces_prefix_prefix = "/alba/osds/ns/"
    let namespaces_prefix ~osd_id =
      namespaces_prefix_prefix ^ (serialize x_int64_be_to osd_id)
    let namespaces_next_prefix ~osd_id =
      Key_value_store.next_prefix (namespaces_prefix ~osd_id)

    let namespaces ~osd_id ~namespace_id =
      (namespaces_prefix ~osd_id) ^ (serialize x_int64_be_to namespace_id)
    let namespaces_extract_namespace_id key =
      let osd_id =
        deserialize
          ~offset:(String.length namespaces_prefix_prefix)
          x_int64_be_from
          key
      in
      let prefix_len = String.length (namespaces_prefix ~osd_id) in
      deserialize
        ~offset:prefix_len
        x_int64_be_from
        key

    let decommissioning_prefix = "/alba/osds/repairing/"
    let decommissioning_next_prefix = Key_value_store.next_prefix decommissioning_prefix
    let decommissioning ~osd_id =
      decommissioning_prefix ^ (serialize x_int64_be_to osd_id)
    let decommissioning_extract_osd_id =
      let prefix_len = String.length decommissioning_prefix in
      deserialize ~offset:prefix_len x_int64_be_from

    let purging_prefix = "/alba/osds/purging/"
    let purging_next_prefix = Key_value_store.next_prefix purging_prefix
    let purging ~osd_id =
      purging_prefix ^ (serialize x_int64_be_to osd_id)
    let purging_extract_osd_id =
      let prefix_len = String.length purging_prefix in
      deserialize ~offset:prefix_len x_int64_be_from
  end

  module Msg_log = struct
    open Protocol.Msg_log
    let prefix_prefix : type dest msg. (dest, msg) t -> string = function
      | Nsm_host -> Nsm_host.msg_log_prefix
      | Osd -> Osd.msg_log_prefix

    let prefix : type dest msg. (dest, msg) t -> dest -> string = fun t dest ->
      let suffix = serialize (dest_to_buffer t) dest in
      (prefix_prefix t) ^ "msgs/" ^ suffix

    let extract_id_from_key key prefix =
      x_int64_be_from (Llio.make_buffer
                         (Key.get_raw key)
                         (1 + String.length prefix))

    let extract_id key prefix =
      x_int64_be_from (Llio.make_buffer
                         key
                         (String.length prefix))

    let next_msg_key : type dest msg. (dest, msg) t -> dest -> string = fun t dest ->
      let suffix = serialize (dest_to_buffer t) dest in
      (prefix_prefix t) ^ "next" ^ suffix
  end

  module Namespace = struct
    let info_prefix = "/alba/ns/list/"
    let info namespace_name = info_prefix ^ namespace_name
    let info_next_prefix = Key_value_store.next_prefix info_prefix
    let info_extract_namespace_name =
      let prefix_len = String.length info_prefix in
      fun key -> Str.string_after key prefix_len

    let next_id = "/alba/ns/next_id"

    let name_prefix = "/alba/ns/by_id/"

    let name namespace_id =
      name_prefix ^ (serialize x_int64_be_to namespace_id)

    let name_extract_id key =
      let prefix_len = String.length name_prefix in
      let b = Llio.make_buffer key prefix_len in
      x_int64_be_from b

    let name_next_prefix = Key_value_store.next_prefix name_prefix

    let osds_prefix_prefix = "/alba/ns/osds/"
    let osds_prefix ~namespace_id =
      osds_prefix_prefix ^ (serialize x_int64_be_to namespace_id)
    let osds_next_prefix ~namespace_id =
      Key_value_store.next_prefix (osds_prefix ~namespace_id)

    let osds ~namespace_id ~osd_id =
      (osds_prefix ~namespace_id) ^ (serialize x_int64_be_to osd_id)
    let osds_extract_osd_id key =
      let namespace_id =
        deserialize
          ~offset:(String.length osds_prefix_prefix)
          x_int64_be_from
          key
      in
      let prefix_len = String.length (osds_prefix ~namespace_id) in
      deserialize
        ~offset:prefix_len
        x_int64_be_from
        key

  end

  module Work = struct
    let next_id = "/alba/work/id/"

    let count = "/alba/work/count"

    let prefix = "/alba/work/items/"
    let prefix_length = String.length prefix
    let next_prefix = Key_value_store.next_prefix prefix

    let job_name_prefix = "/alba/work/job_name/"
    let job_name_prefix_length = String.length job_name_prefix
    let job_name_next_prefix = Key_value_store.next_prefix job_name_prefix

    let job_name name = job_name_prefix ^ name

    let _suffix key pl =
      let key_len = String.length key in
      let len = key_len - pl in
      String.sub key pl len

    let extract_job_name key = _suffix key job_name_prefix_length

    let extract_item_key key = _suffix key prefix_length

  end

  module Preset = struct
    let default = "/alba/preset/default"
    let prefix = "/alba/preset/list/"

    let namespaces_prefix ~preset_name =
      "/alba/preset/namespaces" ^ (serialize Llio.string_to preset_name)
    let namespaces ~preset_name ~namespace_id =
      (namespaces_prefix ~preset_name) ^ (serialize x_int64_be_to namespace_id)
    let namespaces_extract_namespace_id ~preset_name =
      let prefix_len = String.length (namespaces_prefix ~preset_name) in
      fun key -> x_int64_be_from (Llio.make_buffer key prefix_len)

    let initial_update_propagation = "/alba/preset/initial_update_propagation"
    let propagation = "/alba/preset/propagation/"
  end
end

let mark_msgs_delivered_user_function_name = "albamgr_mark_messages_delivered"

module Statistics =
  struct
    include Statistics_collection.Generic
    let show t = show_inner t Albamgr_protocol.Protocol.tag_to_name
  end

let statistics = Statistics_collection.Generic.make ()

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
          (Statistics.show statistics)
        >>= fun () ->
        inner ()
      in
      is_active := true;
      Lwt_log.ign_info "activated mgr statistics reporting";
      Lwt.ignore_result (inner ())
  end

let update_namespace_info (db : read_user_db) name f_some f_none =
  let namespace_info_key = Keys.Namespace.info name in
  let ns_info_s = db # get namespace_info_key in
  match ns_info_s with
  | None -> f_none (), None
  | Some v ->
     let open Protocol in
     let ns_info = deserialize Namespace.from_buffer v in
     let ns_info' = f_some ns_info in
     [ Update.Assert (namespace_info_key, ns_info_s);
       Update.Replace
         (namespace_info_key,
          Some (serialize Namespace.to_buffer ns_info')); ],
     Some ns_info'

let get_namespace_by_id db ~namespace_id =
  let key = Keys.Namespace.name namespace_id in
  match db # get key with
  | None -> None
  | Some namespace_name ->
     let info_key = Keys.Namespace.info namespace_name in
     begin
       match db # get info_key with
       | None -> None
       | Some v ->
          let namespace_info =
            deserialize Protocol.Namespace.from_buffer v
          in
          Some (namespace_name, namespace_info)
     end

let get_namespace_osds
      (db : read_user_db)
      ~namespace_id
      ~first ~finc ~last
      ~max ~reverse =
  let module KV = WrapReadUserDb(
                      struct
                        let db = db
                        let prefix = ""
                      end) in
  let module EKV = Key_value_store.Read_store_extensions(KV) in
  EKV.map_range
    db
    ~first:(Keys.Namespace.osds ~namespace_id ~osd_id:first) ~finc
    ~last:(match last with
           | Some (last, linc) -> Some (Keys.Namespace.osds ~namespace_id ~osd_id:last, linc)
           | None -> Keys.Namespace.osds_next_prefix ~namespace_id)
    ~max ~reverse
    (fun cur key ->
     let osd_id = Keys.Namespace.osds_extract_osd_id key in
     let state = deserialize Protocol.Osd.NamespaceLink.from_buffer (KV.cur_get_value cur) in
     (osd_id, state))


let add_work_items (db : read_user_db) work_items =
  let module W = Protocol.Work in
  let secondary,_ =
    List.fold_left
      (fun (acc,names) item ->
        match item with
        | W.IterNamespace (_, _, name, _) ->
          let key = Keys.Work.job_name_prefix ^ name in
          if StringSet.mem name names || db # exists key
          then
            let open Protocol in
            Error.failwith
              ~payload:(Printf.sprintf "job with name %S exists" name)
              Error.Bad_argument
          else (Some name :: acc, StringSet.add name names)
       | _ -> (None::acc,names)
      )
      ([],StringSet.empty) (List.rev work_items)
  in
  [ Log_plugin.make_update_x64_with_secondary
      ~next_id_key:Keys.Work.next_id
      ~log_prefix:Keys.Work.prefix
      ~msgs:(List.map
               (serialize Protocol.Work.to_buffer)
               work_items)
      ~secondary_prefix:Keys.Work.job_name_prefix
      ~secondary;
    Arith64.make_update
      Keys.Work.count
      Arith64.PLUS_EQ
      (List.length work_items |> Int64.of_int)
      ~clear_if_zero:false;
  ]

let add_msgs : type dest msg.
                    (dest, msg) Protocol.Msg_log.t ->
                    dest -> msg list ->
                    Update.t list =
  fun t dest msgs ->
  [ Log_plugin.make_update_x64
      ~next_id_key:(Keys.Msg_log.next_msg_key t dest)
      ~log_prefix:(Keys.Msg_log.prefix t dest )
      ~msgs:(List.map
               (fun msg ->
                serialize (Protocol.Msg_log.msg_to_buffer t) msg)
               msgs)
  ]
let add_msg t dest msg = add_msgs t dest [ msg ]

let get_osd_by_long_id db long_id =
  let vo = db # get (Keys.Osd.info ~long_id) in
  Option.map (deserialize Protocol.Osd.from_buffer_with_claim_info) vo
let list_osds_by_osd_id db ~first ~finc ~last ~max ~reverse =
  let module KV = WrapReadUserDb(
                      struct
                        let db = db
                        let prefix = ""
                      end) in
  let module EKV = Key_value_store.Read_store_extensions(KV) in
  let (cnt, ids), has_more =
    EKV.map_range
      db
      ~first:(Keys.Osd.osd_id_to_long_id ~osd_id:first) ~finc
      ~last:(match last with
             | None -> Keys.Osd.osd_id_to_long_id_next_prefix
             | Some (osd_id, linc) -> Some (Keys.Osd.osd_id_to_long_id ~osd_id, linc))
      ~max ~reverse
      (fun cur key ->
       let osd_id = Keys.Osd.osd_id_to_long_id_extract_osd_id key in
       let long_id = KV.cur_get_value cur in
       osd_id, long_id) in
  (cnt,
   List.map
     (fun (osd_id, long_id) ->
      let _, osd_info = Option.get_some (get_osd_by_long_id db long_id) in
      (osd_id, osd_info))
     ids),
  has_more
let list_all_osds db =
  let res, _has_more =
    list_osds_by_osd_id
      db
      ~first:0L ~finc:true ~last:None
      ~max:(-1) ~reverse:false in
  res

let list_osds_by_long_id db ~first ~finc ~last ~max ~reverse =
  let module KV = WrapReadUserDb(
                      struct
                        let db = db
                        let prefix = ""
                      end) in
  let module EKV = Key_value_store.Read_store_extensions(KV) in
  EKV.map_range
    db
    ~first:(Keys.Osd.info ~long_id:first) ~finc
    ~last:(match last with
           | None -> Keys.Osd.info_next_prefix
           | Some (long_id, linc) -> Some (Keys.Osd.info ~long_id, linc))
    ~max ~reverse
    (fun cur key ->
     deserialize
       Protocol.Osd.from_buffer_with_claim_info
       (KV.cur_get_value cur))

let get_osd_by_id (db : read_user_db) ~osd_id =
  let long_id_o = db # get (Keys.Osd.osd_id_to_long_id ~osd_id) in
  Option.map
    (fun long_id ->
     Option.get_some (get_osd_by_long_id db long_id))
    long_id_o

let update_namespace_link ~namespace_id ~osd_id from to' =
  let key = Keys.Namespace.osds ~namespace_id ~osd_id in
  [ Update.Assert (key,
                   Some (serialize Protocol.Osd.NamespaceLink.to_buffer from));
    Update.Set (key,
                serialize Protocol.Osd.NamespaceLink.to_buffer to'); ]


let upds_for_delivered_msg
    : type dest msg.
           read_user_db ->
           (dest, msg) Protocol.Msg_log.t -> dest -> msg ->
           Update.t list =
  fun db t dest msg ->
  let open Protocol in
  match t with
  | Msg_log.Nsm_host -> begin
      let open Nsm_host_protocol.Protocol.Message in
      match msg with
      | CreateNamespace (name, id) ->
         let upds, _ =
           update_namespace_info
             db
             name
             (fun ns_info -> Namespace.({ ns_info with state = Active }))
             (fun () -> []) in
         upds
      | DeleteNamespace namespace_id ->
         begin
           match get_namespace_by_id db ~namespace_id with
           | None -> []
           | Some (namespace_name, namespace_info) ->
              let namespace_info_key = Keys.Namespace.info namespace_name in
              let namespace_name_key = Keys.Namespace.name namespace_id in
              let { Namespace.id; nsm_host_id; state } = namespace_info in
              let delete_ns_info =
                [ Update.Assert (namespace_info_key,
                                 Some (serialize Namespace.to_buffer namespace_info));
                  Update.Delete namespace_info_key ;
                  Update.Delete namespace_name_key;
                ]
              in
              let delete_preset_used_by_ns =
                Update.Replace (Keys.Preset.namespaces
                                  ~preset_name:namespace_info.Namespace.preset_name
                                  ~namespace_id,
                                None) in
              let (_, osd_ids), _ =
                let module KV = WrapReadUserDb(
                                    struct
                                      let db = db
                                      let prefix = ""
                                    end) in
                let module EKV = Key_value_store.Read_store_extensions(KV) in
                EKV.map_range
                  db
                  ~first:(Keys.Namespace.osds_prefix ~namespace_id) ~finc:true
                  ~last:(Keys.Namespace.osds_next_prefix ~namespace_id)
                  ~max:(-1) ~reverse:false
                  (fun cur key -> Keys.Namespace.osds_extract_osd_id key)
              in
              let add_work_item =
                add_work_items
                  db
                  [ Work.CleanupNsmHostNamespace (nsm_host_id, namespace_id) ]
              in

              let cleanup_osds =
                List.fold_left
                  (fun acc osd_id ->
                   let upds =
                     Update.Replace (Keys.Namespace.osds ~namespace_id ~osd_id,
                                     None)
                     :: Update.Replace (Keys.Osd.namespaces ~namespace_id ~osd_id,
                                        None)
                     :: add_work_items
                          db
                          [ Work.CleanupOsdNamespace (osd_id, namespace_id) ]
                   in
                   upds::acc)
                  []
                  osd_ids
              in

              List.concat
                [ add_work_item;
                  List.concat cleanup_osds;
                  delete_ns_info;
                  [ delete_preset_used_by_ns; ]; ]
         end
      | RecoverNamespace (name, namespace_id) ->
         (* link all osds that should be linked... *)
         let _, ns_info =
           get_namespace_by_id db ~namespace_id |>
             Option.get_some
         in
         let (_, osds), _ =
           get_namespace_osds
             db
             ~namespace_id
             ~first:0L ~finc:true ~last:None
             ~reverse:false ~max:(-1)
         in
         add_msgs
           Msg_log.Nsm_host
           ns_info.Namespace.nsm_host_id
           (let open Nsm_host_protocol.Protocol in
            List.map
              (fun (osd_id, osd_state) ->
               let _, osd_info = get_osd_by_id db ~osd_id |>
                                   Option.get_some in
               Message.NamespaceMsg
                 (namespace_id,
                  Namespace_message.LinkOsd (osd_id, osd_info)))
              osds)
      | NamespaceMsg (namespace_id, msg) ->
         begin
           let open Nsm_host_protocol.Protocol.Namespace_message in
           match msg with
           | LinkOsd _ -> []
           | UnlinkOsd osd_id ->
              let add_work_item =
                add_work_items
                  db
                  [ Work.WaitUntilRepaired (osd_id, namespace_id) ]
              in
              add_work_item @
                update_namespace_link
                  ~namespace_id ~osd_id
                  Osd.NamespaceLink.Decommissioning
                  Osd.NamespaceLink.Repairing
         end
    end
  | Msg_log.Osd -> begin
      let osd_id = dest in
      let open Osd.Message in
      match msg with
      | AddNamespace (_, namespace_id) ->
         let long_id = db # get_exn (Keys.Osd.osd_id_to_long_id ~osd_id) in
         let osd_info_key = Keys.Osd.info ~long_id in
         let osd_info_v = db # get_exn osd_info_key in
         let _, osd_info = deserialize Osd.from_buffer_with_claim_info osd_info_v in

         if osd_info.Nsm_model.OsdInfo.decommissioned
         then
           begin
             let add_work_items =
               add_work_items db
                 [ Work.CleanupOsdNamespace (osd_id, namespace_id) ]
             in
             [ Update.Replace (Keys.Namespace.osds ~namespace_id ~osd_id, None);
               Update.Replace (Keys.Osd.namespaces ~namespace_id ~osd_id, None);
             ] @ add_work_items
           end
         else
           begin
             match get_namespace_by_id db ~namespace_id with
             | None -> []
             | Some (_, ns_info) ->
                let add_nsm_msg =
                  add_msg
                    Msg_log.Nsm_host
                    ns_info.Namespace.nsm_host_id
                    (let open Nsm_host_protocol.Protocol in
                     Message.NamespaceMsg
                       (namespace_id,
                        Namespace_message.LinkOsd (osd_id, osd_info)))
                in
                List.concat
                  [ (* prevent race by making sure the decommissioned flag
                              hasn't changed in the meantime
                     *)
                    [ Update.Assert (osd_info_key, Some osd_info_v);
                      Update.Set (Keys.Osd.namespaces ~osd_id ~namespace_id, "");
                    ];
                    update_namespace_link
                      ~osd_id ~namespace_id
                      Osd.NamespaceLink.Adding
                      Osd.NamespaceLink.Active;

                    add_nsm_msg ]
           end
    end

let mark_msg_delivered (db : read_user_db) t dest msg_id =
  let open Protocol in
  db # with_cursor
     (fun cur ->
      let prefix = Keys.Msg_log.prefix t dest in
      let found = cur # jump ~inc:true ~right:true prefix in
      if not found
      then []
      else begin
          let key = cur # get_key () in
          if not (Plugin_extra.key_has_prefix prefix key)
          then []
          else begin
              let msg_id' = Keys.Msg_log.extract_id_from_key key prefix in
              if msg_id' <> msg_id
              then Error.failwith ~payload:"Wrong msg_id for mark_msg_delivered" Error.Unknown
              else begin
                  let k = Key.get key in
                  let v = cur # get_value () in
                  let msg = deserialize (Msg_log.msg_from_buffer t) v in
                  Update.Assert (k, Some v) ::
                    Update.Delete k ::
                      (upds_for_delivered_msg db t dest msg)
                end
            end
        end)

let mark_msgs_delivered (db : user_db) t dest msg_id =
  let read_db = (db :> read_user_db) in
  let open Protocol in
  db # with_cursor
     (fun cur ->
      let prefix = Keys.Msg_log.prefix t dest in
      let module KV = WrapReadUserDb(
                          struct
                            let db = read_db
                            let prefix = ""
                          end) in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let (_, msgs), _ =
        EKV.map_range
          read_db
          ~first:prefix ~finc:true
          ~last:(Some (prefix ^ serialize Llio.int32_be_to msg_id,true))
          ~max:(-1) ~reverse:false
          (fun cur key ->
           let msg_id' = Keys.Msg_log.extract_id key prefix in
           let msg = deserialize (Msg_log.msg_from_buffer t) (KV.cur_get_value cur) in
           (key, msg_id', msg))
      in
      List.iter
        (fun (key, msg_id, msg) ->
         let upds = upds_for_delivered_msg read_db t dest msg in
         db # put key None;
         List.iter
           (apply_update db)
           upds)
        msgs)

let ensure_alba_id_and_default_preset db backend =
  match db # get Keys.alba_id with
  | None ->
     (* generate a new one and try to set it *)
     let alba_id =
       let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
       Uuidm.to_string uuid in
     let preset_name = "default" in
     Lwt.catch
       (fun () ->
         backend # push_update
                 (Update.Sequence
                    [ Update.Assert (Keys.alba_id, None);
                      Update.Set (Keys.alba_id, alba_id);

                      (* install default preset only once *)
                      Update.Assert(Keys.Preset.default, None);
                      Update.Set(Keys.Preset.default, preset_name);
                      Update.Set(Keys.Preset.prefix ^ preset_name,
                                 serialize
                                   (Preset.to_buffer ~version:2)
                                   Preset._DEFAULT); ]) >>= fun _ ->
         Lwt.return ())
       (function
        | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
           Lwt.return ()
        | exn ->
           Lwt.fail exn) >>= fun () ->

     (* now read it again from the database as another client might have triggered this too *)
     Lwt.return (db # get_exn Keys.alba_id)
  | Some id ->
     Lwt.return id

let ensure_job_name_index db backend =
  let have = db # get Keys.have_job_name_index in
  begin
  match have with
  |Some _ -> Lwt.return_unit
  |None ->
    begin
      Lwt_log.ign_info "creating job_name_index";
      let module KV = WrapReadUserDb(
                      struct
                        let db = db
                        let prefix = ""
                      end) in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let module W = Albamgr_protocol.Protocol.Work in
      let first = Keys.Work.prefix in
      let last  = Key_value_store.next_prefix first in
      let (cnt,xs),has_more =
        EKV.fold_range
        db
        ~first
        ~finc:true
        ~last
        ~max:(-1)
        ~reverse:false
        (fun cur key (count,acc) ->
          let item_key = Keys.Work.extract_item_key key in
          let vs = KV.cur_get_value cur in
          let buffer = Llio.make_buffer vs 0 in
          try
            let v = W.from_buffer buffer in

            match v with
            | W.IterNamespace (_, _, name, _) ->
               begin
                 Lwt_log.ign_debug_f
                   "fold_range:%S -> name=%S"
                   item_key name;
                 let acc' = (item_key, name) :: acc in
                 let count' = count + 1 in
                 (count',acc')
               end
            | _ -> (count,acc)
          with
            _ -> (count, acc)
        )
        []
      in
      assert (has_more = false);

      let reverse_mappings =
        List.map
          (fun (key,name) ->
            let reverse_key = Keys.Work.job_name  name in
            Update.Set(reverse_key, key))
        xs
      in
      Lwt.catch
        (fun () ->
          backend # push_update
                  (Update.Sequence (
                       Update.Assert (Keys.have_job_name_index, None)
                       :: Update.Set (Keys.have_job_name_index,"")
                       :: reverse_mappings)
                  )
          >>= fun (_:string option) ->
          Lwt.return_unit)
        (function
         | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
            Lwt.return ()
         | exn ->
            Lwt.fail exn)
    end
  end

let ensure_work_item_count db backend =
  match db # get Keys.Work.count with
  | Some _ -> Lwt.return_unit
  | None ->
     let module KV = WrapReadUserDb(
                         struct
                           let db = db
                           let prefix = Keys.Work.prefix
                         end) in
     let module EKV = Key_value_store.Read_store_extensions(KV) in
     let (work_count, ()), _ =
       EKV.fold_range
         db
         ~first:""
         ~finc:true
         ~last:None
         ~max:(-1)
         ~reverse:false
         (fun cur key (count, ()) -> count + 1, ())
         ()
     in

     Lwt.catch
       (fun () ->
         backend # push_update
                 (Update.Sequence
                    [ Update.Assert (Keys.Work.count, None);
                      Update.Set (Keys.Work.count, serialize Llio.int64_to (Int64.of_int work_count));
                 ]) >>= fun (_ : string option) ->

         Lwt.return_unit)
       (function
        | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
           Lwt.return ()
        | exn ->
           Lwt.fail exn)

let albamgr_user_hook : HookRegistry.h = fun (ic, oc, _cid) db backend ->
  ensure_alba_id_and_default_preset db backend >>= fun alba_id ->
  ensure_job_name_index db backend >>= fun () ->
  ensure_work_item_count db backend >>= fun () ->

  let () = maybe_activate_reporting () in

  (* ensure the current version is stored in the database *)
  let get_version () =
    Option.map
      (fun vs -> deserialize Llio.int32_from vs)
      (db # get Keys.albamgr_version)
  in
  begin match get_version () with
    | None ->
      backend # push_update
        (Update.TestAndSet
           (Keys.albamgr_version,
            None,
            Some (serialize Llio.int32_to 0l))) >>= fun _ ->
      Lwt.return ()
    | Some _ ->
      Lwt.return ()
  end >>= fun () ->
  let get_version () = Option.get_some (get_version ()) in

  begin
    match db # get Keys.maintenance_config with
    | None ->
       Lwt.catch
         (fun () ->
          backend # push_update
                  (Update.Sequence
                     [ Update.Assert (Keys.maintenance_config, None);
                       Update.Set (Keys.maintenance_config,
                                   let open Maintenance_config in
                                   serialize
                                     to_buffer
                                     { enable_auto_repair = true;
                                       auto_repair_timeout_seconds = 60. *. 15.;
                                       auto_repair_disabled_nodes = [];
                                       enable_rebalance = true;
                                       cache_eviction_prefix_preset_pairs = Hashtbl.create 0;
                                       redis_lru_cache_eviction = None;
                                     }); ])
          >>= fun _ ->
          Lwt.return ())
         (function
           | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
              (* maintenance_config key should be present *)
              ignore ((db # get_exn Keys.maintenance_config) : string);
              Lwt.return ()
           | exn -> Lwt.fail exn)
    | Some _ ->
       Lwt.return_unit
  end >>= fun () ->

  (* this is the only supported version for now
     we want to ensure here that no old version
     can work on new data *)
  let check_version () =
    0l = get_version () in
  let assert_version_update =
    Update.Assert
      (Keys.albamgr_version,
       Some (serialize Llio.int32_to 0l)) in

  let open Protocol in

  let list_namespaces ~first ~finc ~last ~max ~reverse =
    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = ""
      end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    EKV.map_range
        db
        ~first:(Keys.Namespace.info_prefix ^ first) ~finc
        ~last:(match last with
            | None -> Keys.Namespace.info_next_prefix
            | Some (last, linc) ->
              Some (Keys.Namespace.info_prefix ^ last, linc))
        ~max ~reverse
        (fun cur key ->
           let namespace_name = Keys.Namespace.info_extract_namespace_name key in
           let namespace_info = deserialize Namespace.from_buffer (KV.cur_get_value cur) in
           (namespace_name, namespace_info))
  in

  let list_preset_namespaces ~preset_name ~max =
    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = ""
      end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    let prefix = Keys.Preset.namespaces_prefix ~preset_name in
    EKV.map_range
      db
      ~first:prefix ~finc:true
      ~last:(Key_value_store.next_prefix prefix)
      ~reverse:false ~max
      (fun cur key ->
         Keys.Preset.namespaces_extract_namespace_id ~preset_name key)
  in
  let list_nsm_hosts ~first ~finc ~last ~max ~reverse =
    let module KV = WrapReadUserDb(
                        struct
                          let db = db
                          let prefix = ""
                        end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    EKV.map_range
      db
      ~first:(Keys.Nsm_host.info first) ~finc
      ~last:(match last with
             | None -> Keys.Nsm_host.info_next_prefix
             | Some (l, linc) -> Some (Keys.Nsm_host.info l, linc))
      ~max ~reverse
      (fun cur key ->
       let nsm_host_id = Keys.Nsm_host.info_extract_nsm_host_id key in
       let nsm_host_info = deserialize Nsm_host.from_buffer (KV.cur_get_value cur) in
       (nsm_host_id, nsm_host_info))
  in

  let list_presets ~first ~finc ~last ~max ~reverse =
    let module KV = WrapReadUserDb(
      struct
        let db = db
        let prefix = Keys.Preset.prefix
      end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    let default_preset = db # get Keys.Preset.default in
    let presets =
      EKV.map_range
        db
        ~first ~finc ~last ~max ~reverse
        (fun cur key ->
           let preset_name = key in
           let preset, version =
             deserialize
               (Llio.pair_from
                  Preset.from_buffer
                  (maybe_from_buffer Llio.int64_from 0L))
               (KV.cur_get_value cur)
           in
           let in_use =
             let (cnt, _), _ = list_preset_namespaces ~preset_name ~max:1 in
             cnt > 0
           in
           (preset_name, preset, version, Some preset_name = default_preset, in_use)) in
    presets
  in

  let get_preset_propagation ~preset_name =
    db # get (Keys.Preset.propagation ^ preset_name)
    |> Option.map
         (fun v ->
           let version, namespace_ids = deserialize Preset.Propagation.from_buffer v in
           (version, namespace_ids, v))
  in

  let propagate_preset_version preset_name version =
    let (_, namespace_ids), _ = list_preset_namespaces ~preset_name ~max:(-1) in
    let work_item = add_work_items db [ Work.PropagatePreset preset_name ] in
    let assert_preset_namespaces =
      Update.Assert_range
        (Keys.Preset.namespaces_prefix ~preset_name,
         Range_assertion.ContainsExactly
           (List.map
              (fun namespace_id ->
                Keys.Preset.namespaces
                  ~preset_name
                  ~namespace_id)
              namespace_ids))
    in
    let propagation_state_updates =
      let propagation_key = Keys.Preset.propagation ^ preset_name in
      match get_preset_propagation ~preset_name with
      | None ->
         [ Update.Assert (propagation_key, None);
           Update.Set (propagation_key,
                       serialize
                         Preset.Propagation.to_buffer
                         (version, namespace_ids)
                      ); ]
      | Some (version', namespace_ids', v) ->
         if version >= version'
         then [ Update.Assert (propagation_key, Some v);
                Update.Set (propagation_key,
                            serialize
                              Preset.Propagation.to_buffer
                              (version, namespace_ids)
                           ); ]
         else []
    in
    work_item
    @ assert_preset_namespaces
    :: propagation_state_updates
  in

  begin
    match db # get Keys.Preset.initial_update_propagation with
    | None ->
       Lwt.catch
         (fun () ->
           let (_, all_presets), _ =
             list_presets
               ~first:"" ~finc:true ~last:None
               ~max:(-1) ~reverse:false in

           let assert_all_presets_unchanged =
             Update.Assert_range (Keys.Preset.prefix,
                                  Range_assertion.ContainsExactly
                                    (List.map
                                       (fun (p, _, version, _, _) -> Keys.Preset.prefix ^ p)
                                       all_presets))
           in

           let propagate_all_presets =
             List.flatmap
               (fun (preset_name, _, version, _, _) ->
                 propagate_preset_version preset_name version)
               all_presets
           in

           backend # push_update
                   (Update.Sequence
                      (Update.Assert (Keys.Preset.initial_update_propagation, None)
                       :: Update.Set (Keys.Preset.initial_update_propagation, "")
                       :: assert_all_presets_unchanged
                       :: propagate_all_presets)
                   ) >>= fun _ ->
           Lwt.return ())
         (function
          | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
             db # get_exn Keys.Preset.initial_update_propagation |> ignore;
             Lwt.return ()
          | exn ->
             Lwt.fail exn)
    | Some _ ->
       Lwt.return_unit
  end >>= fun () ->

  let get_next_msgs : type dest msg. (dest, msg) Msg_log.t -> dest -> (Msg_log.id * msg) counted_list_more =
    fun t dest ->
    begin
      let module  KV = WrapReadUserDb(struct let db = db let prefix = "" end) in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let first = Keys.Msg_log.prefix t dest in
      let last  = Key_value_store.next_prefix first in
      EKV.map_range
        db
        ~first:first
        ~finc:true
        ~last:last
        ~max:10 (* don't overdo it *)
        ~reverse:false
        (fun cur key ->
         let msg_id = Keys.Msg_log.extract_id key first in
         let msg_s = KV.cur_get_value cur in
         let msg = deserialize (Msg_log.msg_from_buffer t) msg_s in
         (msg_id,msg)
        )
    end
  in

  let check_claim_osd long_id =
    let info_key = Keys.Osd.info ~long_id in
    let info_serialized, (claim_info, osd_info) = match db # get info_key with
      | None -> Error.failwith Error.Osd_unknown
      | Some v ->
        v,
        deserialize Osd.from_buffer_with_claim_info v
    in

    if claim_info <> Osd.ClaimInfo.Available
    then Error.failwith Error.Osd_already_claimed;

    info_key, info_serialized,
    claim_info, osd_info
  in

  let add_namespace_osd
      ~osd_id
      ~namespace_id ~namespace_name ~namespace_info
      f_removing
    =
    let not_removing =
      let open Namespace in
      match namespace_info.state with
      | Creating
      | Active
      | Recovering -> true
      | Removing -> false
    in
    if not_removing
    then begin
      let osd_link_key = Keys.Namespace.osds ~namespace_id ~osd_id in
      if db # get osd_link_key <> None
      then Error.failwith Error.Osd_already_linked_to_namespace;

      let assert_namespace_state =
        Update.Assert (Keys.Namespace.info namespace_name,
                       Some (serialize Namespace.to_buffer namespace_info)) in
      let link_osd =
        [ Update.Assert (osd_link_key, None);
          Update.Set (osd_link_key,
                      serialize Osd.NamespaceLink.to_buffer Osd.NamespaceLink.Adding) ]in
      let add_msg_upds =
        add_msg
          Msg_log.Osd
          osd_id
          (Osd.Message.AddNamespace (namespace_name, namespace_id)) in
      let upds =
        List.concat [ [ assert_namespace_state ];
                      link_osd;
                      add_msg_upds; ] in
      upds
    end else
      f_removing ()
  in

  let get_lease ~lease_name =
    let lease_key = Keys.lease ~lease_name in
    let lease_so = db # get lease_key in
    let lease = match lease_so with
      | None -> 0
      | Some s -> deserialize Llio.int_from s
    in
    (lease_key, lease_so, lease)
  in

  let get_progress name =
    let key = Keys.progress name in
    let v_o = db # get key in
    let open Albamgr_protocol.Protocol.Progress in
    key,
    v_o,
    Option.map
      (deserialize from_buffer)
      v_o
  in
  let get_progress_for_prefix name =
    let first = Keys.progress name in
    let module KV = WrapReadUserDb(
                        struct
                          let db = db
                          let prefix = ""
                        end) in
    let module EKV = Key_value_store.Read_store_extensions(KV) in
    EKV.map_range
      db
      ~first ~finc:true ~last:(Key_value_store.next_prefix first)
      ~max:(-1) ~reverse:false
      (fun cur key ->
       let i = deserialize ~offset:(String.length first) Llio.int_from key in
       i, deserialize Progress.from_buffer (KV.cur_get_value cur)
      )
    |> fst
  in

  let get_maintenance_config () =
    let s = db # get_exn Keys.maintenance_config in
    let cfg = deserialize Maintenance_config.from_buffer s in
    s, cfg
  in

  let handle_update
    : type i o. (i, o) update -> i ->
      (o * Update.t list) Lwt.t =
    let return_upds upds = Lwt.return ((), upds) in
    let make_update_osd_updates long_id osd_changes acc =
      let open Protocol in
      let info_key = Keys.Osd.info ~long_id in
      let info_serialized, (claim_info, osd_info_current) =
        match db # get info_key with
        | None -> Error.(failwith Osd_unknown)
        | Some v ->
           v,
           deserialize Osd.from_buffer_with_claim_info v
      in

      let osd_info_new = Osd.Update.apply osd_info_current osd_changes in
      let upds =
        Update.Assert (info_key, Some info_serialized)
        :: Update.Set (info_key,
                       serialize
                         (Osd.to_buffer_with_claim_info ~version:3)
                         (claim_info, osd_info_new))
        :: acc;
      in
      upds
    in
    let add_osd osd =
      (* this adds the osd to the albamgr without claiming it *)

       let info_key =
         Keys.Osd.info
           ~long_id:(let open Nsm_model in OsdInfo.get_long_id osd.OsdInfo.kind)
       in
       if None <> (db # get info_key)
       then Error.failwith Error.Osd_already_exists;


       let upds = [ Update.Assert (info_key, None);
                    Update.Set (info_key,
                                serialize
                                  (Osd.to_buffer_with_claim_info ~version:3)
                                  (Osd.ClaimInfo.Available, osd)); ]
       in
       Lwt.return ((), upds)
    in
    let decommission_osd ~long_id =
      let info_key = Keys.Osd.info ~long_id in
      let info_serialized, (claim_info, osd_info_current) =
        match db # get info_key with
        | None -> Error.(failwith Osd_unknown)
        | Some v ->
          v,
          deserialize Osd.from_buffer_with_claim_info v
      in

      (* sanity checks *)
      let osd_id =
        let open Osd.ClaimInfo in
        match claim_info with
        | ThisAlba osd_id -> osd_id
        | AnotherAlba _
        | Available -> Error.(failwith ~payload:"osd not claimed by this instance" Unknown)
      in
      if osd_info_current.Nsm_model.OsdInfo.decommissioned
      then Error.(failwith Osd_already_decommissioned);

      let osd_info_new = Nsm_model.OsdInfo.({
          osd_info_current with
          decommissioned = true;
        }) in

      let upd_info =
        [ Update.Assert (info_key, Some info_serialized);
          Update.Set (info_key,
                      serialize
                        (Osd.to_buffer_with_claim_info ~version:3)
                        (claim_info, osd_info_new)); ]
      in

      let module KV = WrapReadUserDb(
        struct
          let db = db
          let prefix = ""
        end) in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let (_, namespace_ids), _ = EKV.map_range
          db
          ~first:(Keys.Osd.namespaces_prefix ~osd_id) ~finc:true
          ~last:(Keys.Osd.namespaces_next_prefix ~osd_id)
          ~max:(-1) ~reverse:false
          (fun cur key -> Keys.Osd.namespaces_extract_namespace_id key)
      in

      let unlink_from_namespaces =
        List.fold_left
          (fun acc namespace_id ->
             let _, ns_info = Option.get_some (get_namespace_by_id db ~namespace_id) in
             let new_upds =
               add_msg
                 Msg_log.Nsm_host
                 ns_info.Namespace.nsm_host_id
                 (let open Nsm_host_protocol.Protocol in
                  Message.NamespaceMsg
                    (namespace_id,
                     Namespace_message.UnlinkOsd osd_id))
             in
             new_upds :: acc)
          []
          namespace_ids
      in

      let add_to_decommissioned_osds = Update.Set (Keys.Osd.decommissioning ~osd_id, "") in
      let add_work_item =
        add_work_items
          db
          [ Work.WaitUntilDecommissioned osd_id ]
      in

      let upd_namespace_links =
        List.fold_left
          (fun acc namespace_id ->
             List.concat [
               update_namespace_link
                 ~namespace_id ~osd_id
                 Osd.NamespaceLink.Active
                 Osd.NamespaceLink.Decommissioning;
               acc
             ])
          []
          namespace_ids
      in

      let upds = List.concat [
          add_work_item;
          [ add_to_decommissioned_osds; ] ;
          List.flatten unlink_from_namespaces;
          upd_namespace_links;
          upd_info;
        ]
      in
      upds
    in
    let purge_osd ~long_id ~osd_id =
      [ Update.Delete (Keys.Osd.info ~long_id);
        Update.Delete (Keys.Osd.osd_id_to_long_id ~osd_id);
        Update.DeletePrefix (Keys.Msg_log.prefix Msg_log.Osd osd_id); ]
    in
    let _bump_int64_next_id int64_from int64_to  next_id_key new_next_id =
       let vo = db # get next_id_key in
       let next_id = match vo with
         | None -> 0L
         | Some v -> deserialize int64_from v
       in
       if Int64.(new_next_id <: next_id)
       then Error.(failwith Unknown)
       else return_upds [ Update.Assert (next_id_key, vo);
                          Update.Set (next_id_key, serialize int64_to new_next_id); ]
    in
    function
    | AddNsmHost -> fun (id, nsm_host) ->
      let nsm_host_info_key = Keys.Nsm_host.info id in
      begin match db # get nsm_host_info_key with
        | Some _ ->
          Error.failwith Error.Nsm_host_already_exists
        | None ->
          return_upds
            [ Update.TestAndSet
                (nsm_host_info_key,
                 None,
                 Some (serialize Nsm_host.to_buffer nsm_host)) ]
      end
    | UpdateNsmHost -> fun (id, nsm_host) ->
      let nsm_host_info_key = Keys.Nsm_host.info id in
      begin match db # get nsm_host_info_key with
        | None ->
          Error.failwith Error.Nsm_host_unknown
        | Some nsm_host_s ->
          let open Nsm_host in
          let nsm_host_old = deserialize from_buffer nsm_host_s in
          if nsm_host_old.lost
          then assert nsm_host.lost;
          return_upds
            [ Update.Set (nsm_host_info_key,
                                 serialize Nsm_host.to_buffer nsm_host) ]
      end
    | AddOsd  -> fun osd -> add_osd osd
    | AddOsd2 -> fun osd -> add_osd osd
    | AddOsd3 -> fun osd -> add_osd osd

    | UpdateOsd ->
       fun (long_id, osd_changes) ->
       let upds = make_update_osd_updates long_id osd_changes [] in
       return_upds upds
    | UpdateOsds ->
       fun updates ->
       begin
         let upds =
           List.fold_left
             (fun acc (long_id,osd_changes) ->
             make_update_osd_updates long_id osd_changes acc
             ) [] updates
         in
         return_upds upds
       end
    | UpdateOsds2 ->
       fun updates ->
       begin
         let upds =
           List.fold_left
             (fun acc (long_id,osd_changes) ->
             make_update_osd_updates long_id osd_changes acc
             ) [] updates
         in
         return_upds upds
       end
    | DecommissionOsd -> fun long_id ->
      Lwt.return ((), decommission_osd ~long_id)
    | MarkOsdClaimed -> fun long_id ->
      let info_key, info_serialized,
          claim_info, osd_info =
        check_claim_osd long_id
      in

      let next_id_key = Keys.Osd.next_id in
      let next_id_so = db # get next_id_key in
      let osd_id =
        Option.get_some_default
          0L
          (Option.map (deserialize x_int64_from) next_id_so)
      in

      let (_, all_presets), _ =
        list_presets
          ~first:"" ~finc:true ~last:None
          ~max:(-1) ~reverse:false in
      (* TODO getting to this point could be made more efficient with an index... *)
      let presets_with_all_osds =
        List.filter
          (fun (_name, preset, _, _is_default, _) ->
             preset.Preset.osds = Preset.All)
          all_presets
      in
      let add_osd_to_namespaces_upds =
        List.flatmap_unordered
          (fun (preset_name, _, _, _, _) ->
             let (_, namespace_ids), _ =
               list_preset_namespaces
                 ~preset_name
                 ~max:(-1) in
             List.flatmap_unordered
               (fun namespace_id ->
                  let namespace_name, namespace_info =
                    Option.get_some (get_namespace_by_id db ~namespace_id) in
                  add_namespace_osd
                    ~osd_id
                    ~namespace_id
                    ~namespace_name
                    ~namespace_info
                    (fun () -> []))
               namespace_ids)
          presets_with_all_osds
      in

      let assert_namespaces_in_presets =
        List.map
          (fun (preset_name, _, _, _, _) ->
             let (_, namespace_ids), _ = list_preset_namespaces ~preset_name ~max:(-1) in
             Update.Assert_range (Keys.Preset.namespaces_prefix ~preset_name,
                                  Range_assertion.ContainsExactly
                                    (List.map
                                       (fun namespace_id ->
                                          Keys.Preset.namespaces
                                            ~preset_name
                                            ~namespace_id)
                                       namespace_ids)))
          presets_with_all_osds
      in

      let osd_id_to_long_id_key = Keys.Osd.osd_id_to_long_id ~osd_id in
      let osd_info' =
        let open Nsm_model.OsdInfo in
        { osd_info with
          claimed_since = Some (Unix.gettimeofday())
        }
      in
      let upds =
        List.concat
          [ [ Update.Assert (info_key, Some info_serialized);
              Update.Set (info_key,
                          serialize
                            (Osd.to_buffer_with_claim_info ~version:3)
                            (Osd.ClaimInfo.ThisAlba osd_id, osd_info'));
              Update.Assert (next_id_key, next_id_so);
              Update.Set (next_id_key, serialize x_int64_to (Int64.succ osd_id));
              Update.Assert (osd_id_to_long_id_key, None);
              Update.Set (osd_id_to_long_id_key, long_id); ];
            assert_namespaces_in_presets;
            add_osd_to_namespaces_upds ]
      in
      Lwt.return (osd_id, upds)
    | MarkOsdClaimedByOther -> fun (long_id, alba_id') ->
      if alba_id = alba_id'
      then Error.failwith Error.Unknown;

      let info_key = Keys.Osd.info ~long_id in
      let info_serialized, (claim_info, osd_info) = match db # get info_key with
        | None -> Error.(failwith Osd_unknown)
        | Some v ->
          v,
          deserialize Osd.from_buffer_with_claim_info v
      in

      if claim_info <> Osd.ClaimInfo.Available
      then Error.failwith Error.Osd_already_claimed;

      let upds =
        [ Update.Assert (info_key, Some info_serialized);
          Update.Set (info_key,
                      serialize
                        (Osd.to_buffer_with_claim_info ~version:3)
                        (Osd.ClaimInfo.AnotherAlba alba_id', osd_info)); ]
      in

      Lwt.return ((), upds)
    | CreateNamespace -> fun (name, nsm_host_id, preset_o) ->

      let preset_name = match preset_o with
        | None ->
           begin
             match db # get Keys.Preset.default with
             | None -> Error.(failwith Invalid_preset)
             | Some p -> p
           end
        | Some p -> p
      in
      let namespace_info_key = Keys.Namespace.info name in
      begin match db # get namespace_info_key with
        | Some _ ->
          Error.failwith Error.Namespace_already_exists
        | None ->
          let next_id_s = db # get Keys.Namespace.next_id in
          let namespace_id = match next_id_s with
            | None -> 0L
            | Some s -> deserialize x_int64_from s in

          let add_nsm_host_msg =
            add_msg
              Msg_log.Nsm_host
              nsm_host_id
              (Nsm_host_protocol.Protocol.Message.CreateNamespace (name, namespace_id))
          in
          let bump_next_namespace_id =
            [ Update.Assert (Keys.Namespace.next_id, next_id_s);
              Update.Set (Keys.Namespace.next_id,
                          serialize x_int64_to (Int64.succ namespace_id)); ]
          in
          let ns_info = Namespace.{ id = namespace_id;
                                    nsm_host_id;
                                    state = Creating;
                                    preset_name; } in
          let set_ns_info =
            [ Update.Assert (namespace_info_key, None);
              Update.Set (namespace_info_key,
                          serialize
                            Namespace.to_buffer
                            ns_info);
              Update.Set (Keys.Namespace.name namespace_id, name);
            ]
          in
          let preset, preset_version = match db # get (Keys.Preset.prefix ^ preset_name) with
            | None -> Error.failwith Error.Preset_does_not_exist
            | Some p -> deserialize
                          (Llio.pair_from
                             Preset.from_buffer
                             (maybe_from_buffer Llio.int64_from 0L))
                          p
          in

          let add_preset_work_item =
            add_work_items db [ Work.PropagatePreset preset_name; ]
          in
          let update_propagation_state =
            let propagation_key = Keys.Preset.propagation ^ preset_name in
            match db # get propagation_key with
            | None ->
               [ Update.Assert (propagation_key, None);
                 Update.Set (propagation_key,
                             serialize
                               Preset.Propagation.to_buffer
                               (preset_version, [ namespace_id; ])
                            ); ]
            | Some v ->
               let version', namespace_ids' = deserialize Preset.Propagation.from_buffer v in
               (* assert (version' = preset_version); *)
               if version' = preset_version
               then
                 [ Update.Assert (propagation_key, Some v);
                   Update.Set (propagation_key,
                               serialize
                                 Preset.Propagation.to_buffer
                                 (version', namespace_id :: namespace_ids')
                              ); ]
               else
                 let msg = Printf.sprintf
                             "%S version'=%Li <> preset_version=%Li"
                             preset_name version' preset_version
                 in
                 failwith msg
          in

          let osd_ids =
            let ids = match preset.Preset.osds with
              | Preset.All -> List.map fst (snd (list_all_osds db))
              | Preset.Explicit osd_ids -> osd_ids in
            List.filter
              (fun osd_id ->
                 let _, osd_info = Option.get_some (get_osd_by_id db ~osd_id) in
                 not osd_info.Nsm_model.OsdInfo.decommissioned)
              ids
          in

          let mark_preset_used_by_namespace =
            Update.Set (Keys.Preset.namespaces
                          ~preset_name
                          ~namespace_id,
                        "") in
          let add_osds_upds =
            List.flatmap_unordered
              (fun osd_id ->
                 let osd_link_key = Keys.Namespace.osds ~namespace_id ~osd_id in
                 let add_link =
                   Update.Set (osd_link_key,
                               serialize
                                 Osd.NamespaceLink.to_buffer
                                 Osd.NamespaceLink.Adding)
                 in
                 let add_msg_upds =
                   add_msg
                     Msg_log.Osd
                     osd_id
                     (Osd.Message.AddNamespace (name, namespace_id)) in
                 add_link :: add_msg_upds)
              osd_ids in
          let incr_count =
            [Arith64.make_update
               (Keys.Nsm_host.count nsm_host_id)
               Arith64.PLUS_EQ 1L
               ~clear_if_zero:true;
            ]
          in
          let upds =
            List.concat
              [ add_nsm_host_msg;
                bump_next_namespace_id;
                set_ns_info;
                add_osds_upds;
                [ mark_preset_used_by_namespace; ];
                add_preset_work_item;
                update_propagation_state;
                incr_count;
              ]
          in
          Lwt.return (ns_info, upds)
      end
    | DeleteNamespace -> fun name ->

      let update_ns_info, ns_info =
        update_namespace_info
          db
          name
          (fun ns_info ->
             let open Namespace in
             if ns_info.state = Active
             then { ns_info with state = Removing }
             else Error.failwith Error.Unknown)
          (fun () -> Error.failwith Error.Namespace_does_not_exist) in
      let ns_info = Option.get_some ns_info in
      let nsm_host_id = ns_info.Namespace.nsm_host_id in
      let add_nsm_host_msg =
        add_msg
          Msg_log.Nsm_host
          nsm_host_id
          (Nsm_host_protocol.Protocol.Message.DeleteNamespace ns_info.Namespace.id)
      in

      let decr_count =
            [Arith64.make_update
               (Keys.Nsm_host.count nsm_host_id)
               Arith64.PLUS_EQ (-1L)
               ~clear_if_zero:true;
            ]
      in
      let upds =
        List.concat [ decr_count;
                      update_ns_info;
                      add_nsm_host_msg;
                    ]
      in
      Lwt.return (nsm_host_id, upds)
    | RecoverNamespace -> fun (namespace, nsm_host_id) ->

      let namespace_info_key = Keys.Namespace.info namespace in
      let ns_info_so = db # get namespace_info_key in

      begin match ns_info_so with
        | None -> Error.(failwith Namespace_does_not_exist)
        | Some ns_info_s ->
          let open Namespace in

          let ns_info = deserialize from_buffer ns_info_s in

          let old_nsm_host_id = ns_info.nsm_host_id in
          let old_nsm_host =
            deserialize
              Nsm_host.from_buffer
              (db # get_exn (Keys.Nsm_host.info old_nsm_host_id))
          in
          if not old_nsm_host.Nsm_host.lost
          then Error.(failwith Nsm_host_not_lost);

          let namespace_id = ns_info.id in

          let update_state_send_msg state' nsm_host_msg =
            let ns_info' = { ns_info with
                             state = state';
                             nsm_host_id; }
            in
            let update_ns_info =
              [ Update.Assert (namespace_info_key, ns_info_so);
                Update.Set
                  (namespace_info_key,
                   (serialize Namespace.to_buffer ns_info')); ]
            in

            let add_nsm_host_msg =
              add_msg
                Msg_log.Nsm_host
                nsm_host_id
                nsm_host_msg
            in
            let upds =
              List.concat [ update_ns_info;
                            add_nsm_host_msg; ] in
            Lwt.return ((), upds)
          in

          let open Nsm_host_protocol.Protocol.Message in

          begin match ns_info.state with
            | Creating ->
              update_state_send_msg
                Creating
                (CreateNamespace (namespace, namespace_id))
            | Active
            | Recovering ->
              update_state_send_msg
                Recovering
                (RecoverNamespace (namespace, namespace_id))
            | Removing ->
              Error.(failwith Unknown)
              (* TODO
                 client moet langs buitenaf maar doen alsof alle berichten zijn toegekomen? *)
          end
      end
    | MarkMsgDelivered t ->
      fun (dest, msg_id) ->
        Lwt_log.debug_f "MarkMsgDelivered(...,msg_id:%Li)" msg_id >>= fun () ->
        return_upds (mark_msg_delivered db t dest msg_id)
    | MarkMsgsDelivered t ->
       fun (dest, msg_id) ->
       return_upds
         [ Update.UserFunction
             (mark_msgs_delivered_user_function_name,
              Some
                (serialize
                   (Llio.tuple3_to
                      Msg_log.to_buffer
                      (Msg_log.dest_to_buffer t)
                      x_int64_to)
                   (Msg_log.Wrap t,
                    dest,
                    msg_id))) ]
    | AddWork ->
       fun (_cnt, work) ->
       let updates = add_work_items db work in
       return_upds updates
    | MarkWorkCompleted -> fun id ->
      let work_key = Keys.Work.prefix ^ serialize x_int64_be_to id in
      let upds = match db # get work_key with
        | None -> []
        | Some v ->
          let work = deserialize Work.from_buffer v in
          let open Work in
          match work with
          | CleanupNsmHostNamespace _
          | CleanupOsdNamespace _
          | CleanupNamespaceOsd _
          | RepairBadFragment _
          | RewriteObject _
          | IterNamespaceLeaf _ -> []
          | IterNamespace (action, namespace_id, name, cnt) ->

            let get_key i = get_start_key i cnt in

            let items =
              List.map
                (fun i ->
                 let start = get_key i |> Option.get_some in
                 let range = start, get_key (i + 1) in
                 let name = serialize
                              (Llio.pair_to
                                 Llio.raw_string_to
                                 Llio.int_to)
                              (name, i) in
                 let progress =
                   let open Progress in
                   match action with
                   | Rewrite ->
                      (Rewrite { count = 0L; next = Some start; })
                   | Verify _ ->
                      (Verify ({ count = 0L; next = Some start; },
                               { fragments_detected_missing  = 0L;
                                 fragments_osd_unavailable   = 0L;
                                 fragments_checksum_mismatch = 0L; })) in
                 Work.IterNamespaceLeaf
                   (action,
                    namespace_id,
                    name,
                    range),
                 Update.Set (Keys.progress name,
                             serialize Progress.to_buffer progress)
                )
                (Int.range 0 cnt)
            in

            let add_work_items = add_work_items db (List.map fst items) in
            let update_progress = List.map snd items in
            add_work_items @ update_progress
          | WaitUntilRepaired (osd_id, namespace_id) ->
            let add_work =
              add_work_items
                db
                [ Work.CleanupNamespaceOsd (namespace_id, osd_id);
                  Work.CleanupOsdNamespace (osd_id, namespace_id); ]  in

            let key1 = Keys.Namespace.osds ~namespace_id ~osd_id in
            let key2 = Keys.Osd.namespaces ~namespace_id ~osd_id in
            let deletes =
              [ Update.Replace (key1, None);
                Update.Replace (key2, None); ]
            in
            add_work @ deletes
          | WaitUntilDecommissioned osd_id ->
             begin
               let remove_x = Update.Replace (Keys.Osd.decommissioning ~osd_id, None); in
               let purging_key = Keys.Osd.purging ~osd_id in
               match db # get purging_key with
               | None ->
                  [ remove_x ]
               | Some _ as vo ->
                  let long_id = db # get_exn (Keys.Osd.osd_id_to_long_id ~osd_id) in
                  Update.Assert (purging_key, vo)
                  :: remove_x
                  :: purge_osd ~osd_id ~long_id
             end
          | PropagatePreset _ ->
             []
      in
      return_upds
        (Arith64.make_update
           Keys.Work.count
           Arith64.PLUS_EQ (-1L)
           ~clear_if_zero:false
         :: Update.Assert_exists work_key
         :: Update.Delete work_key
         :: upds)
    | CreatePreset -> fun (preset_name, preset) ->

      if not (Preset.is_valid preset)
      then Error.(failwith Invalid_preset);

      let preset_key = Keys.Preset.prefix ^ preset_name in
      begin match db # get preset_key with
        | Some _ -> Error.failwith Error.Preset_already_exists
        | None -> ()
      end;

      return_upds
        [ Update.Assert (preset_key, None);
          Update.Set (preset_key,
                      serialize
                        (Llio.pair_to
                           (Preset.to_buffer ~version:2)
                           Llio.int64_to)
                        (preset, 0L)
                     );
        ]

    | DeletePreset -> fun preset_name ->
      let current_default = db # get Keys.Preset.default in
      let maybe_remove_default =
        if current_default = Some preset_name
        then [ Update.Assert (Keys.Preset.default, current_default);
               Update.Delete (Keys.Preset.default); ]
        else []
      in

      let (cnt, _), _ = list_preset_namespaces ~preset_name ~max:1 in
      let is_in_use = cnt <> 0 in

      if is_in_use
      then Error.failwith Error.Preset_cant_delete_in_use;

      let preset_key = Keys.Preset.prefix ^ preset_name in
      begin match db # get preset_key with
        | None -> Error.failwith Error.Preset_does_not_exist
        | Some _ -> ()
      end;

      return_upds
        (List.concat
           [ [ Update.Assert_range
                 (Keys.Preset.namespaces_prefix ~preset_name,
                  Range_assertion.ContainsExactly []);
               Update.Delete (preset_key);
               Update.Replace (Keys.Preset.propagation ^ preset_name, None);
             ];
             maybe_remove_default ])
    | SetDefaultPreset -> fun preset_name ->
      let preset_key = Keys.Preset.prefix ^ preset_name in
      let preset_v = begin match db # get preset_key with
        | None -> Error.failwith Error.Preset_does_not_exist
        | Some v -> v
      end in
      return_upds
        [ Update.Set (Keys.Preset.default, preset_name);
          (* asserting it still exists when we make it the default *)
          Update.Assert (preset_key, Some preset_v); ]
    | AddOsdsToPreset -> fun (preset_name, (_, osd_ids)) ->

      let preset_key = Keys.Preset.prefix ^ preset_name in
      let preset_v = begin match db # get preset_key with
        | None -> Error.failwith Error.Preset_does_not_exist
        | Some v -> v
      end in
      let preset, version =
        deserialize
          (Llio.pair_from
             Preset.from_buffer
             (maybe_from_buffer Llio.int64_from 0L))
          preset_v
      in

      let current_osd_ids = match preset.Preset.osds with
        | Preset.All -> Error.failwith Error.Unknown
        | Preset.Explicit os -> os in

      let preset' =
        Preset.({ preset with
                  osds =
                    Explicit
                      (List.sort_uniq
                         compare
                         (List.concat [ current_osd_ids; osd_ids; ]);) }) in

      let (_, namespace_ids), _ = list_preset_namespaces ~preset_name ~max:(-1) in
      let add_namespace_osds_upds =
        List.flatmap
          (fun osd_id ->
             List.concat
               (List.map
                  (fun namespace_id ->
                     let namespace_name, namespace_info =
                       Option.get_some (get_namespace_by_id db ~namespace_id) in
                     add_namespace_osd
                       ~osd_id
                       ~namespace_id
                       ~namespace_name
                       ~namespace_info
                       (fun () -> []))
                  namespace_ids))
          osd_ids
      in

      let version' = Int64.succ version in

      return_upds
        (List.concat
           [[ Update.Assert_range (Keys.Preset.namespaces_prefix ~preset_name,
                                   Range_assertion.ContainsExactly
                                     (List.map
                                        (fun namespace_id ->
                                           Keys.Preset.namespaces
                                             ~preset_name
                                             ~namespace_id)
                                        namespace_ids));
              Update.Assert (preset_key, Some preset_v);
              Update.Set (preset_key, serialize
                                        (Llio.pair_to
                                           (Preset.to_buffer ~version:2)
                                           Llio.int64_to)
                                        (preset', version'));
            ];
            add_namespace_osds_upds ])
    | UpdatePreset ->
      fun (preset_name, preset_update) ->
      let preset_key = Keys.Preset.prefix ^ preset_name in
      let preset_v = begin match db # get preset_key with
        | None -> Error.failwith Error.Preset_does_not_exist
        | Some v -> v
      end in
      let preset, version =
        deserialize
          (Llio.pair_from
             Preset.from_buffer
             (maybe_from_buffer Llio.int64_from 0L))
          preset_v
      in
      let preset' = Preset.Update.apply preset preset_update in
      let version' = Int64.succ version in
      return_upds
        (Update.Assert (preset_key, Some preset_v)
         :: Update.Set (preset_key, serialize
                                      (Llio.pair_to
                                         (Preset.to_buffer ~version:2)
                                         Llio.int64_to)
                                      (preset', version'))
         :: propagate_preset_version preset_name version')
    | UpdatePresetPropagationState ->
       fun (preset_name, preset_version, namespace_ids) ->
       let upds =
         match get_preset_propagation ~preset_name with
         | None -> []
         | Some (version', namespace_ids', v) ->
            if preset_version <> version'
            then []
            else
              begin
                let namespace_ids =
                  List.filter
                    (fun namespace_id -> not (List.mem namespace_id namespace_ids))
                    namespace_ids'
                in
                let key = Keys.Preset.propagation ^ preset_name in
                [ Update.Assert (key, Some v);
                  Update.Set (key,
                              serialize
                                Preset.Propagation.to_buffer
                                (version', namespace_ids));
                ]
              end
       in
       return_upds upds
    | StoreClientConfig -> fun ccfg ->
      return_upds [ Update.Set
                      (Keys.client_config,
                       serialize Alba_arakoon.Config.to_buffer ccfg); ]
    | TryGetLease -> fun (lease_name, counter) ->
      let lease_key, lease_so, lease = get_lease ~lease_name in
      if lease <> counter
      then Error.(failwith Claim_lease_mismatch);

      return_upds [ Update.Assert (lease_key, lease_so);
                    Update.Set (lease_key, (serialize Llio.int_to (lease + 1))); ]
    | RegisterParticipant ->
      fun (prefix, (name, cnt)) ->
      let key = Keys.participants ~prefix ~name in
      return_upds [ Update.Set (key, serialize Llio.int_to cnt); ]
    | RemoveParticipant ->
      fun (prefix, (name, cnt)) ->
      let key = Keys.participants ~prefix ~name in
      let upds = match db # get key with
        | None -> []
        | Some v ->
           let cnt' = deserialize Llio.int_from v in
           if cnt' = cnt
           then [ Update.Assert (key, Some v);
                  Update.Replace (key, None); ]
           else []
      in
      return_upds upds
    | UpdateProgress ->
      fun (name, upd) ->
      begin
        let key, v_o, p_o = get_progress name in
        match p_o with
        | None -> Error.(failwith Progress_does_not_exist)
        | Some p ->
           let open Progress.Update in
           match upd with
           | CAS (old, new_o) ->
             if old <> p
             then Error.(failwith Progress_CAS_failed)
             else
               begin

                 let extra =
                   if new_o = None
                   then
                     begin
                       let base_name_len = String.length name - 4 in
                       let base_name =
                         String.sub name 0 base_name_len in
                       let id =
                         let buf = Llio.make_buffer name base_name_len in
                         Llio.int_from buf
                       in
                       let jn_key = Keys.Work.job_name base_name in
                       if id = 0
                       then
                         [Update.Replace (jn_key, None)]
                       else
                         []
                     end
                   else
                     []

                 in
                 return_upds
                   ([ Update.Assert (key, v_o);
                      Update.Replace (key,
                                      Option.map
                                        (serialize Progress.to_buffer)
                                        new_o);
                    ] @ extra)
               end
      end
    | UpdateMaintenanceConfig ->
      fun update ->
      let s, cfg = get_maintenance_config () in
      let new_cfg = Maintenance_config.Update.apply cfg update in
      Lwt.return
        (new_cfg,
         [ Update.Assert (Keys.maintenance_config, Some s);
           Update.Set    (Keys.maintenance_config,
                          serialize Maintenance_config.to_buffer new_cfg); ])
    | PurgeOsd ->
       fun long_id ->

       let info_key = Keys.Osd.info ~long_id in
       let info_serialized, (claim_info, osd_info) =
         match db # get info_key with
         | None -> Error.(failwith Osd_unknown)
         | Some v ->
            v,
            deserialize Osd.from_buffer_with_claim_info v
       in

       let assert_osd_info = Update.Assert (info_key, Some info_serialized) in
       let updates =
         let open Osd.ClaimInfo in
         match claim_info with
         | AnotherAlba _
         | Available ->
            (* this osd has not been used, we can just delete it's
             * osd_info and be done with it. *)
            [ assert_osd_info;
              Update.Delete info_key; ]
         | ThisAlba osd_id ->
            begin
              let purging_key = Keys.Osd.purging ~osd_id in
              match db # get purging_key with
              | Some _ ->
                 (* already purging, so nothing to be done here *)
                 []
              | None ->
                 begin
                   let set_purging = Update.Set (purging_key, "") in
                   if not osd_info.Nsm_model.OsdInfo.decommissioned
                   then
                     set_purging :: decommission_osd ~long_id
                   else
                     begin
                       let decommissioning_key = Keys.Osd.decommissioning ~osd_id in
                       match db # get decommissioning_key with
                       | None ->
                          (* osd is already fully decommissioned, so just delete osd info
                           * and add it to the purge list so all it's (cleanup) tasks can
                           * be finished and removed.
                           *)
                          assert_osd_info
                          :: set_purging
                          :: purge_osd ~osd_id ~long_id
                       | Some _ as vo ->
                          (* add osd to purge list + assert that the osd is still
                           * decommissioning
                           *)
                          [ assert_osd_info;
                            set_purging;
                            Update.Assert (decommissioning_key, vo); ]
                     end
                 end
            end
       in
       Lwt.return ((), updates)
    | BumpNextWorkItemId  -> _bump_int64_next_id x_int64_be_from x_int64_be_to Keys.Work.next_id
    | BumpNextOsdId       -> _bump_int64_next_id x_int64_from    x_int64_to    Keys.Osd.next_id
    | BumpNextNamespaceId -> _bump_int64_next_id x_int64_from    x_int64_to    Keys.Namespace.next_id
  in

  let handle_query : type i o. (i, o) query -> i -> o =
  let list_decommissioning_osds { RangeQueryArgs.first; finc; last; reverse; max; } =
    let module KV = WrapReadUserDb(struct
          let db = db
          let prefix = ""
        end)
      in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      EKV.map_range
        db
        ~first:(Keys.Osd.decommissioning ~osd_id:first) ~finc
        ~last:(match last with
            | Some (last, linc) -> Some (Keys.Osd.decommissioning ~osd_id:last, linc)
            | None -> Keys.Osd.decommissioning_next_prefix)
        ~max:(cap_max ~max ()) ~reverse
        (fun cur key ->
           let osd_id = Keys.Osd.decommissioning_extract_osd_id key in
           let _, osd_info = Option.get_some (get_osd_by_id db ~osd_id) in
           osd_id, osd_info)
  in

  function
    | ListNsmHosts -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      let (cnt, hosts), has_more =
        list_nsm_hosts
          ~first ~finc ~last
          ~max:(cap_max ~max ())
          ~reverse
      in
      let hosts' =
        List.map
          (fun (id, info) ->
             let count = match db # get (Keys.Nsm_host.count id) with
               | None -> 0L
               | Some v -> deserialize Llio.int64_from v
             in
             id, info, count)
          hosts
      in
      (cnt, hosts'), has_more

    | ListOsdsByOsdId -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_osd_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListOsdsByOsdId2 -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_osd_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListOsdsByOsdId3 -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_osd_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListOsdsByLongId -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_long_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListOsdsByLongId2 -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_long_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListOsdsByLongId3 -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_osds_by_long_id
        db
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListAvailableOsds -> fun () ->
      let (_, osds), _ =
        list_osds_by_long_id
          db
          ~first:"" ~finc:true ~last:None
          ~max:(-1) ~reverse:false
      in
      let osds' =
        List.filter
          (fun (claim_info, osd_info) -> claim_info = Osd.ClaimInfo.Available)
          osds
      in
      (List.length osds', List.map snd osds')
    | ListNamespaces -> fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
      list_namespaces
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | ListNamespaceOsds -> fun (namespace_id,
                                { RangeQueryArgs.first; finc; last; max; reverse; }) ->

      if None = get_namespace_by_id db ~namespace_id
      then Error.failwith Error.Namespace_does_not_exist;

      get_namespace_osds
        db
        ~namespace_id
        ~first ~finc ~last
        ~max:(cap_max ~max ())
        ~reverse
    | GetNextMsgs t -> fun id ->
      get_next_msgs t id
    | GetWork -> fun { GetWorkParams.first; finc; last; max; reverse; } ->
      let module KV = WrapReadUserDb(
        struct
          let db = db
          let prefix = Keys.Work.prefix
        end) in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let items =
        EKV.map_range
          db
          ~first:(serialize x_int64_be_to first) ~finc
          ~last:(Option.map
                   (fun (last, linc) ->
                      (serialize x_int64_be_to last,
                       linc))
                   last)
          ~max:(cap_max ~cap:10_000 ~max ())
          ~reverse
          (fun cur key ->
             let work_id = deserialize x_int64_be_from key in
             let work_t = deserialize Work.from_buffer (KV.cur_get_value cur) in
             (work_id, work_t))
      in
      items
    | GetWorkCount ->
       fun () ->
       begin
         match db # get Keys.Work.count with
         | Some v -> deserialize Llio.int64_from v
         | None -> failwith "no persisted work count available"
       end
    | GetAlbaId -> fun () ->
      alba_id
    | ListPresets ->
       fun { RangeQueryArgs.first; finc; last; max; reverse } ->
       let (cnt, items), has_more =
         list_presets
           ~first ~finc ~last
           ~max:(cap_max ~max ())
           ~reverse
       in
       ((cnt,
         List.map
           (fun (name, preset, _, x, y) -> name, preset, x, y)
           items),
        has_more)
    | ListPresets2 ->
       fun { RangeQueryArgs.first; finc; last; max; reverse } ->
       list_presets
         ~first ~finc ~last
         ~max:(cap_max ~max ())
         ~reverse
    | ListPresetNamespaces ->
       fun preset_name ->
       list_preset_namespaces ~preset_name ~max:(-1) |> fst
    | GetPresetsPropagationState ->
       fun preset_names ->
       List.map
         (fun preset_name ->
           get_preset_propagation ~preset_name
           |> Option.map (fun (v, ids, _) -> v, ids))
         preset_names
    | GetClientConfig -> fun () ->
      db # get_exn Keys.client_config |>
      deserialize Alba_arakoon.Config.from_buffer
    | ListNamespacesById ->
       fun { RangeQueryArgs.first; finc; last; max; reverse; } ->
       let module KV = WrapReadUserDb(
                           struct
                             let db = db
                             let prefix = ""
                           end)
       in
       let module EKV = Key_value_store.Read_store_extensions(KV) in
       let r =
         EKV.map_range
           db
           ~first:(Keys.Namespace.name first) ~finc
           ~last:(match last with
                  | None -> Keys.Namespace.name_next_prefix
                  | Some (l, linc) -> Some (Keys.Namespace.name l, linc))
           ~max:(cap_max ~max ())
           ~reverse
           (fun cur key_s ->
            let name = KV.cur_get_value cur in
            let id = Keys.Namespace.name_extract_id key_s in
            let info_s = db # get_exn (Keys.Namespace.info name) in
            let info = deserialize Namespace.from_buffer info_s in
            (id, name, info)
           )
       in
       Plugin_helper.debug_f
         "ListNamespacesById: %s"
         ([%show: (int * (int64 * string * Namespace.t) list) * bool] r);
       r
    | GetVersion ->
      fun () -> Alba_version.summary
    | CheckClaimOsd ->
      fun long_id ->
        let _ = check_claim_osd long_id in
        ()
    | ListDecommissioningOsds  -> list_decommissioning_osds
    | ListDecommissioningOsds2 -> list_decommissioning_osds
    | ListDecommissioningOsds3 -> list_decommissioning_osds
    | ListOsdNamespaces -> fun (osd_id,
                                { RangeQueryArgs.first; finc; last; reverse; max; }) ->
      let module KV = WrapReadUserDb(struct
          let db = db
          let prefix = ""
        end)
      in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      EKV.map_range
        db
        ~first:(Keys.Osd.namespaces ~osd_id ~namespace_id:first) ~finc
        ~last:(match last with
            | Some (last, linc) -> Some (Keys.Osd.namespaces ~osd_id ~namespace_id:last, linc)
            | None -> Keys.Osd.namespaces_next_prefix ~osd_id)
        ~max:(cap_max ~max ()) ~reverse
        (fun cur key -> Keys.Osd.namespaces_extract_namespace_id key)
    | Statistics -> Statistics.snapshot statistics
    | CheckLease -> fun lease_name ->
      let lease_key, lease_so, lease = get_lease ~lease_name in
      lease
    | GetParticipants ->
      fun prefix ->
      let keys_prefix = Keys.participants ~prefix ~name:"" in
      let module KV = WrapReadUserDb(struct
          let db = db
          let prefix = keys_prefix
        end)
      in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let res, _ =
        EKV.map_range
          db
          ~first:"" ~finc:true ~last:None
          ~max:(-1) ~reverse:false
          (fun cur name ->
           let cnt = deserialize Llio.int_from (KV.cur_get_value cur) in
           (name, cnt))
      in
      res
    | GetProgress ->
      fun name ->
      let _, _, p = get_progress name in
      p
    | GetProgressForPrefix -> get_progress_for_prefix
    | GetMaintenanceConfig ->
      fun () ->
      let _, cfg = get_maintenance_config () in
      cfg
    | ListPurgingOsds ->
      fun { RangeQueryArgs.first; finc; last; reverse; max; } ->
      let module KV =
        WrapReadUserDb(struct
                          let db = db
                          let prefix = ""
                        end)
      in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      EKV.map_range
        db
        ~first:(Keys.Osd.purging ~osd_id:first) ~finc
        ~last:(match last with
               | None -> Keys.Osd.purging_next_prefix
               | Some (osd_id, linc) -> Some (Keys.Osd.purging ~osd_id, linc))
        ~max ~reverse
        (fun cur key -> Keys.Osd.purging_extract_osd_id key)
    | ListJobs ->
       fun {RangeQueryArgs.first;finc;last;reverse;max;} ->
       let module KV =
        WrapReadUserDb(struct
                          let db = db
                          let prefix = ""
                        end)
      in
      let module EKV = Key_value_store.Read_store_extensions(KV) in
      let last = match last with
        | None -> Keys.Work.job_name_next_prefix
        | Some (last,linc) -> Some (Keys.Work.job_name last, linc)
      in
      EKV.map_range
        db
        ~first:(Keys.Work.job_name first) ~finc
        ~last
        ~max
        ~reverse
        (fun cur key -> Keys.Work.extract_job_name key)
  in

  let write_response_ok serializer res =
    Lwt.return
      (fun () ->
        let s =
          serialize
            (Llio.pair_to Llio.int32_to serializer)
            (0l, res) in
        Plugin_helper.debug_f
          "Albamgr: Writing ok response (4+%i bytes)"
          (String.length s);
        Lwt_extra2.llio_output_and_flush oc s)
  in
  let write_response_error payload err =
    Lwt.return
      (fun () ->
        Plugin_helper.debug_f "Albamgr: Writing error response %s" (Error.show err);
        let s =
          serialize
            (Llio.pair_to
               Llio.int_to
               Llio.string_to)
            (Error.err2int err, payload) in
        Lwt_extra2.llio_output_and_flush oc s)
  in

  let do_one statistics () =
    Plugin_helper.debug_f "Albamgr: Waiting for new request";
    Llio.input_string ic >>= fun req_s ->
    let req_buf = Llio.make_buffer req_s 0 in
    let tag = Llio.int32_from req_buf in
    Plugin_helper.debug_f "Albamgr: Got %s" (Protocol.tag_to_name tag);
    match tag_to_command tag with
      | Wrap_q r ->
        let consistency = Consistency.from_buffer req_buf in
        let read_allowed =
          try
            backend # read_allowed consistency;
            true
          with _ -> false
        in
        if not (check_version ())
        then write_response_error "" Error.Old_plugin_version
        else if read_allowed
        then
          Lwt.catch
            (fun () ->
             let (delta,(res,res_serializer)) =
               with_timing
               (fun () ->
                let req = read_query_i r req_buf in
                let res = handle_query r req in
                let res_serializer = write_query_o r in
                (res,res_serializer))
             in
             Statistics.new_delta statistics tag delta;
             write_response_ok res_serializer res
            )
            (function
              | Error.Albamgr_exn (err, payload) -> write_response_error payload err
              | exn ->
                let msg = Printexc.to_string exn in
                Plugin_helper.info_f "Albamgr: unknown exception : %s" msg;
                write_response_error msg Error.Unknown)
        else
          write_response_error "" Error.Inconsistent_read
      | Wrap_u r -> begin
          let req = read_update_i r req_buf in
          let rec try_update = function
            | 5 ->
              (* TODO if the optimistic concurrency fails too many times then
                      automatically turn it into a user function? *)
              Lwt.fail_with
                (Printf.sprintf
                   "Albamgr: too many retries for operation %s"
                   (Protocol.tag_to_name tag))
            | cnt ->
               Lwt.catch
                 (fun () ->
                  with_timing_lwt
                    (fun () ->
                     handle_update r req >>= fun (res, upds) ->
                     backend # push_update
                             (Update.Sequence
                                (assert_version_update :: upds))
                     >>= fun _ ->
                     Lwt.return (`Succes res)
                    )
                  >>= fun (delta,r) ->
                  Statistics.new_delta statistics tag delta;
                  Lwt.return r
                 )
                 (function
                   | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_ASSERTION_FAILED ->
                      Plugin_helper.info_f
                        "Albamgr: Assert failed %s (attempt %i)" msg cnt;
                      Lwt.return `Retry
                   | Protocol_common.XException (rc, msg) when rc = Arakoon_exc.E_NOT_MASTER ->
                      Error.failwith Error.Not_master
                   | exn -> Lwt.return (`Fail exn))
               >>= function
               | `Succes res -> Lwt.return res
               | `Retry -> try_update (cnt + 1)
               | `Fail exn -> Lwt.fail exn in
          Lwt.catch
            (fun () ->
             if not (check_version ())
             then write_response_error "" Error.Old_plugin_version
             else begin
                 try_update 0 >>= fun res ->
                 let serializer = write_update_o r in
                 write_response_ok serializer res
               end)
            (function
              | End_of_file as exn -> Lwt.fail exn
              | Error.Albamgr_exn (err, payload) -> write_response_error payload err
              | exn ->
                 let msg = Printexc.to_string exn in
                 Plugin_helper.info_f "Albamgr: unknown exception : %s" msg;
                 write_response_error msg Error.Unknown)
        end
  in
  let rec inner () =
    Lwt.catch
      (fun () ->
        do_one statistics () >>= fun f_write_response ->
        f_write_response ())
      (function
       | Error.Albamgr_exn (Error.Unknown_operation as err, payload) ->
          write_response_error payload err >>= fun f_write_response ->
          f_write_response ()
       | exn -> Lwt.fail exn)
    >>= fun () ->
    inner ()
  in

  (* confirm the user hook could be found *)
  Llio.output_int32 oc 0l >>= fun () ->

  inner ()



let () = Registry.register
           mark_msgs_delivered_user_function_name
           (fun user_db ->
            function
            | None -> assert false
            | Some req_s ->
               let buf = Llio.make_buffer req_s 0 in
               let open Protocol in
               match Msg_log.from_buffer buf with
               | Msg_log.Wrap msg_t ->
                  let dest = Msg_log.dest_from_buffer msg_t buf in
                  let msg_id = Llio.int32_from buf in
                  mark_msgs_delivered user_db msg_t dest msg_id;
                  None)
let () = HookRegistry.register "albamgr" albamgr_user_hook
let () = Log_plugin.register ()
let () = Arith64.register()


let () =
  let open Alba_version in
  Lwt_log.ign_info_f
    "albamgr_plugin (%i,%i,%i) git_revision:%s"
    major minor patch git_revision
