(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Lwt.Infix

type bucket_safety = {
    bucket : (int * int * int * int);
    count  : int64;
    applicable_dead_osds : int;
    remaining_safety : int;
  } [@@deriving show, yojson]

let get_namespace_safety
      (alba_client : Alba_client.alba_client)
      ns_info dead_ns_osds =
  let open Albamgr_protocol.Protocol in
  let open Nsm_model in
  let namespace_id = ns_info.Namespace.id in

  Lwt_list.map_p
    (fun osd_id ->
       alba_client # osd_access # get_osd_info ~osd_id >>= fun (osd_info, _, _) ->
       Lwt.return (osd_id, osd_info.OsdInfo.node_id))
    dead_ns_osds
  >>= fun osds_with_node_id ->

  alba_client # nsm_host_access # get_nsm_by_id ~namespace_id >>= fun nsm ->

  nsm # get_stats >>= fun { Nsm_model.NamespaceStats.bucket_count; } ->
  let res =
    List.filter
      (fun (policy, cnt) -> Int64.(cnt >: 0L))
      (snd bucket_count) |>
    List.map
      (fun (bucket, count) ->
         let k, m, fragment_count, max_disks_per_node = bucket in
         let applicable_dead_osds =
           Policy.get_applicable_osd_count
             max_disks_per_node
             osds_with_node_id
         in
         { bucket;
           count;
           applicable_dead_osds;
           remaining_safety = max ((fragment_count-k) - applicable_dead_osds) (-k);
         }
      ) |>
    List.sort
      (fun s1 s2 -> compare s1.remaining_safety s2.remaining_safety)
  in

  Lwt.return res


let get_disk_safety alba_client namespaces dead_osds =

  (* remove any duplicates *)
  let dead_osds = List.sort_uniq compare dead_osds in

  Lwt_list.map_p
    (fun osd_id ->
       alba_client # mgr_access # list_all_osd_namespaces ~osd_id
       >>= fun (_, osd_namespaces) ->
       let r =
         List.map
           (fun namespace_id -> (osd_id, namespace_id))
           osd_namespaces
       in
       Lwt.return r)
    dead_osds
  >>= fun osd_namespaces ->

  let dead_namespace_osds =
    List.group_by
      (fun (osd_id, namespace_id) -> namespace_id)
      (List.flatten_unordered osd_namespaces)
  in

  let get_dead_namespace_osds ~namespace_id =
    try List.map fst (Hashtbl.find dead_namespace_osds namespace_id)
    with Not_found -> []
  in

  Lwt_list.map_p
    (fun (namespace, ns_info) ->
      let open Albamgr_protocol.Protocol in
      let namespace_id = ns_info.Namespace.id in
      Lwt.catch
        (fun () ->
          get_namespace_safety
            alba_client
            ns_info
            (get_dead_namespace_osds ~namespace_id) >>= fun r ->
          Lwt.return (Some (namespace, r)))
        (function
         | Nsm_model.Err.Nsm_exn (Nsm_model.Err.Namespace_id_not_found, _)
         | Error.Albamgr_exn (Error.Namespace_does_not_exist, _) as exn ->
            Lwt_log.info_f
              ~exn
              "Ignoring an exception while determining disk-safety for namespace (%s,%Li), because it indicates the namespace was deleted"
              namespace namespace_id >>= fun () ->
            Lwt.return_none
         | exn -> Lwt.fail exn)
    )
    namespaces
  >|= List.map_filter Std.id
