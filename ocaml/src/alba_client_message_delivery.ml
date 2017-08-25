(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Slice
open Checksum
open Lwt.Infix
open Alba_client_common
module Osd_sec = Osd
module DK = Osd_keys.AlbaInstance

let _get_next_msg_id client prio =

  client # global_kvs # get_option
         prio
         (Slice.wrap_string DK.next_msg_id)
  >>= fun next_id_so ->
  let next_id = match next_id_so with
    | None -> 0L
    | Some next_id_s ->
       let module L = Llio2.ReadBuffer in
       L.deserialize' L.x_int64_from next_id_s
  in
  Lwt.return (next_id_so, next_id)

let _deliver_osd_messages (osd_access : Osd_access_type.t) ~osd_id msgs =

  let get_next_msg_id () =
    osd_access
      # with_osd
      ~osd_id
      (fun client ->
        _get_next_msg_id client (osd_access # get_default_osd_priority)
      )
  in
  let do_one msg_id msg =
    Lwt_log.debug_f
      "Delivering msg %Li to %Li: %s"
      msg_id
      osd_id
      ([%show : Albamgr_protocol.Protocol.Osd.Message.t] msg) >>= fun () ->
    osd_access # with_osd
      ~osd_id
      (fun client ->
       get_next_msg_id () >>= fun (next_id_so, next_id) ->
       if Int64.(next_id =: msg_id)
       then begin
           let open Albamgr_protocol.Protocol.Osd.Message in
           begin
             match msg with
             | AddNamespace (namespace_name, namespace_id) ->
                client # add_namespace namespace_id >>= fun () ->
                let namespace_status_key = DK.namespace_status ~namespace_id in
                Lwt.return
                  ([ Osd.Assert.none_string namespace_status_key; ],
                   [ Osd.Update.set_string
                       namespace_status_key
                       Osd.Osd_namespace_state.(serialize to_buffer Active)
                       Checksum.NoChecksum true;
                     Osd.Update.set_string
                       (DK.namespace_name ~namespace_id) namespace_name
                       Checksum.NoChecksum true;
                   ])
           end >>= fun (asserts, upds) ->
           let bump_msg_id =
             Osd.Update.set_string
               DK.next_msg_id
               (serialize x_int64_to (Int64.succ next_id))
               Checksum.NoChecksum
               true
           in
           let asserts' =
             Osd.Assert.value_option
               (Slice.wrap_string DK.next_msg_id)
               (Option.map
                  (fun x -> Asd_protocol.Blob.Lwt_bytes x)
                  next_id_so)
             :: asserts
           in
           client # global_kvs # apply_sequence
                  (osd_access # get_default_osd_priority)
                  asserts'
                  (bump_msg_id :: upds)
           >>=
             let open Osd_sec in
             (function
               | Ok  _ -> Lwt.return ()
               | Error x ->
                  Lwt_log.warning ([%show : Error.t] x)
                  >>= fun () ->
                  Error.lwt_fail x
             )
         end
       else if Int64.(next_id >: msg_id)
       then Lwt.return ()
       else
         begin
           let msg =
             Printf.sprintf
               "Osd msg_id (%Li) too far off"
               msg_id
           in
           Lwt_log.warning msg >>= fun () ->
           Lwt.fail_with msg
         end
      )
  in

  get_next_msg_id () >>= fun (next_id_so, next_id) ->

  Lwt_list.iter_s
    (fun (msg_id, msg) ->
     if msg_id >= next_id
     then do_one msg_id msg
     else Lwt.return_unit)
    msgs

let deliver_osd_messages mgr_access nsm_host_access osd_access ~osd_id =
  Lwt_log.debug_f "Delivering osd messages for %Li" osd_id >>= fun () ->
  Alba_client_message_delivery_base.deliver_messages
    mgr_access
    Albamgr_protocol.Protocol.Msg_log.Osd
    osd_id
    (_deliver_osd_messages osd_access ~osd_id)

let deliver_nsm_host_messages mgr_access nsm_host_access osd_access ~nsm_host_id =
  Lwt_log.debug_f "Delivering nsm host messages for %s" nsm_host_id >>= fun () ->
  nsm_host_access # get_nsm_host_info ~nsm_host_id >>= fun nsm_host_info ->
  let open Albamgr_protocol.Protocol in
  Alba_client_message_delivery_base.deliver_messages
    mgr_access
    Msg_log.Nsm_host
    nsm_host_id
    (fun msgs ->
     if nsm_host_info.Nsm_host.lost
     then Lwt.return_unit
     else (nsm_host_access # get ~nsm_host_id) # deliver_messages msgs)


let deliver_all_messages is_master mgr_access nsm_host_access osd_access =
  let deliver_nsm_messages =
    Maintenance_common.maintenance_for_all_x
      "deliver nsm messages"
      (fun () -> mgr_access # list_all_nsm_hosts ())
      (fun (nsm_host_id, _, _) ->
       deliver_nsm_host_messages
         mgr_access nsm_host_access osd_access
         ~nsm_host_id)
      (fun (nsm_host_id, _, _) -> nsm_host_id)
      [%show : (string * Albamgr_protocol.Protocol.Nsm_host.t * int64)]
      is_master
  in

  let deliver_osd_messages =
    Maintenance_common.maintenance_for_all_x
      "deliver osd messages"
      (fun () ->
       let osds =
         Hashtbl.fold
           (fun osd_id _ (cnt, acc) -> cnt+1, osd_id::acc)
           (osd_access # osds_info_cache)
           (0, [])
       in
       Lwt.return osds)
      (fun osd_id ->
       deliver_osd_messages
         mgr_access nsm_host_access osd_access
         ~osd_id)
      Std.id
      Int64.to_string
      is_master
  in
  Lwt.choose [ deliver_nsm_messages;
               deliver_osd_messages; ]

let deliver_osd_messages_deduped
      osd_msg_delivery_threads
      mgr_access nsm_host_access osd_access ~osd_id =
  match Hashtbl.find_option osd_msg_delivery_threads osd_id with
  | None ->
     let rec inner wakers =
       Lwt.catch
         (fun () ->
           deliver_osd_messages
             mgr_access nsm_host_access osd_access
             ~osd_id >>= fun () ->
           List.iter
             (fun waker -> Lwt.wakeup waker ())
             wakers;
           Lwt.return_unit
         )
         (fun exn ->
           List.iter
             (fun waker -> Lwt.wakeup_exn waker exn)
             wakers;
           Lwt.fail exn
         )
     in
     let inner wakers =
       Lwt_extra2.with_timeout_no_cancel 5. (fun () -> inner wakers)
     in
     Hashtbl.replace osd_msg_delivery_threads osd_id [];
     Lwt.finalize
       (fun () -> inner [])
       (fun () ->
         let () =
           let wakers = Hashtbl.find osd_msg_delivery_threads osd_id in
           if wakers <> []
           then
             begin
               Hashtbl.replace osd_msg_delivery_threads osd_id [];
               Lwt.async (fun () -> inner wakers)
             end
           else
             Hashtbl.remove osd_msg_delivery_threads osd_id
         in
         Lwt.return_unit
       )
  | Some wakers ->
     let t, waker = Lwt.wait () in
     Hashtbl.replace osd_msg_delivery_threads osd_id (waker :: wakers);
     t

let deliver_messages_to_most_osds
      mgr_access nsm_host_access osd_access
      osd_msg_delivery_threads
      ~osds ~preset ~delivered =
  let mvar = Lwt_mvar.create_empty () in

  Lwt.ignore_result begin
      let osds_delivered = ref [] in
      let finished = ref false in

      Lwt_list.iter_p
        (fun (osd_id, (_ : Albamgr_protocol.Protocol.Osd.NamespaceLink.state)) ->
         Lwt_extra2.ignore_errors
           (fun () ->
             deliver_osd_messages_deduped
               osd_msg_delivery_threads
               mgr_access nsm_host_access osd_access ~osd_id >>= fun () ->

             let () = delivered () in
             osds_delivered := osd_id :: !osds_delivered;
             osd_access # osds_to_osds_info_cache !osds_delivered >>= fun osds_info_cache ->
             if get_best_policy
                  preset.Preset.policies
                  osds_info_cache = None
             then
               Lwt.return ()
             else
               begin
                 if not !finished
                 then
                   begin
                     finished := true;
                     Lwt_mvar.put mvar ()
                   end
                 else
                   Lwt.return ()
               end
           )
        )
        osds
    end;

  Lwt.choose
    [ Lwt_mvar.take mvar;
      Lwt_unix.sleep 2. ]
