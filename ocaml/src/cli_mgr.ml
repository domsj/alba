(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Lwt.Infix
open Cli_common
open Cmdliner

let alba_list_namespaces cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file tls_config ~attempts
      (fun client ->
         client # list_all_namespaces >>= fun (cnt, namespaces) ->
         if to_json
         then begin
           let res =
             List.map
               (fun (name, info) -> Alba_json.Namespace.make name info)
               namespaces
           in
           print_result res Alba_json.Namespace.t_list_to_yojson
         end else
           Lwt_io.printlf
             "Found the following namespaces: %s"
             ([%show: (string * Albamgr_protocol.Protocol.Namespace.t) list]
                namespaces)
      )
  in
  lwt_cmd_line ~to_json ~verbose t


let alba_list_namespaces_cmd =
  Term.(pure alba_list_namespaces
        $ alba_cfg_url
        $ tls_config
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info "list-namespaces" ~doc:"list all namespaces"


let alba_list_namespaces_by_id cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       let first = 0L
       and finc = true
       and last = None
       and max = -1 in
       client # list_namespaces_by_id ~first ~finc ~last ~max
       >>= fun ((cnt,r),more) ->
       if to_json
       then
         let r' =
           `List [`Assoc (List.map
                     (fun (id,name,_info) ->
                      (Int64.to_string id),`String name)
                     r
                  );
                  `Bool more
                 ]
         in
         Lwt_io.printl (Yojson.Safe.to_string r')
       else
         begin
           Lwt_list.iter_s
             (fun (id, name, _info ) ->
              Lwt_io.printlf "%8Li:%S" id name
             ) r
           >>= fun () ->
           if more
           then Lwt_io.printl "..."
           else Lwt.return ()
         end
      )
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_namespaces_by_id_cmd =
  Term.(pure alba_list_namespaces_by_id
        $ alba_cfg_url
        $ tls_config
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info "list-namespaces-by-id"
            ~doc:"show id to name mapping"

let recover_namespace cfg_file tls_config namespace nsm_host_id verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
         client # recover_namespace ~namespace ~nsm_host_id)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let recover_namespace_cmd =
  Term.(pure recover_namespace
        $ alba_cfg_url
        $ tls_config
        $ namespace 0
        $ nsm_host 1
        $ verbose
        $ attempts 1
  ),
  Term.info
    "recover-namespace"
    ~doc:"recover an existing namespace from which the metadata got lost to another nsm host"

let alba_list_osds cfg_file tls_config node_id to_json verbose attempts =

  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
         client # list_all_claimed_osds
         >>= fun (i,devices) ->

         let open Albamgr_protocol.Protocol.Osd in

         let (i',devices') =
           match node_id
           with
           | None -> (i,devices)
           | Some node_id ->
              begin
                let r =
                  List.filter
                  (fun (_,osd) ->
                   node_id = osd.Nsm_model.OsdInfo.node_id) devices
                in
                (List.length r, r)
              end
         in
         if to_json
         then begin
           client # get_alba_id >>= fun alba_id ->
           let res =
             List.map
               (fun (id, info) -> Alba_json.Osd.make alba_id (ClaimInfo.ThisAlba id) info)
               devices'
           in
           print_result res Alba_json.Osd.t_list_to_yojson
         end else begin
           Lwt_io.printlf "\n%i devices" i' >>= fun ()->
           Lwt_list.iter_s
             (fun (d_id,d_info) ->
                Lwt_io.printlf
                  "%Li : %s" d_id
                  (Nsm_model.OsdInfo.show d_info)
             )
             devices'
         end)
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_osds_cmd =
  let alba_list_osds_t =
    Term.(pure alba_list_osds
          $ alba_cfg_url
          $ tls_config
          $ node_id None
          $ to_json
          $ verbose
          $ attempts 1

    )
  in
  let info =
    let doc = "list registered osds" in
    Term.info "list-osds" ~doc
  in
  alba_list_osds_t, info

let alba_list_all_osds alba_cfg_url tls_config node_id to_json verbose attempts =
  let t () =
    with_albamgr_client
      alba_cfg_url ~attempts tls_config
      (fun client ->
         client # list_all_osds
         >>= fun (i,devices) ->
         client # get_alba_id >>= fun alba_id ->
         let (i',devices') =
           match node_id
           with
           | None -> (i,devices)
           | Some node_id ->
              begin
                let r =
                  List.filter
                  (fun (_,osd) ->
                   let open Nsm_model.OsdInfo in
                   node_id = osd.node_id) devices
                in
                (List.length r, r)
              end
         in
         if to_json
         then begin
           let res =
             List.map
               (fun (claim, info) -> Alba_json.Osd.make alba_id claim info)
               devices'
           in
           print_result res Alba_json.Osd.t_list_to_yojson
         end else begin
           Lwt_io.printlf "\n%i devices" i' >>= fun ()->
           Lwt_list.iter_s
             (fun (claim, d_info) ->
                let open Albamgr_protocol.Protocol in
                Lwt_io.printlf
                  "%s : %s"
                  (Osd.ClaimInfo.show claim)
                  (Nsm_model.OsdInfo.show d_info)
             )
             devices'
         end)
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_all_osds_cmd =
  let alba_list_all_osds_t =
    Term.(pure alba_list_all_osds
          $ alba_cfg_url
          $ tls_config
          $ node_id None
          $ to_json
          $ verbose
          $ attempts 1
    )
  in
  let info =
    let doc = "list registered osds" in
    Term.info "list-all-osds" ~doc
  in
  alba_list_all_osds_t, info


let alba_list_available_osds alba_cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      alba_cfg_file ~attempts tls_config
      (fun client -> client # list_available_osds) >>= fun (cnt, osds) ->
    if to_json
    then begin
      let res =
        List.map
          (fun info -> Alba_json.Osd.make "" Albamgr_protocol.Protocol.Osd.ClaimInfo.Available info)
          osds
      in
      print_result res Alba_json.Osd.t_list_to_yojson
    end else
      Lwt_log.info_f
        "Found %i available osds: %s"
        cnt
        ([%show : Nsm_model.OsdInfo.t list] osds)
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_available_osds_cmd =
  Term.(pure alba_list_available_osds
        $ alba_cfg_url
        $ tls_config
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "list-available-osds"
    ~doc:"list known osds still available for claiming by this alba instance"


let alba_list_nsm_hosts cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
         client # list_all_nsm_hosts ()) >>= fun (cnt, nsm_hosts) ->
    if to_json
    then begin
      let res =
        List.map
          (fun (id, info, cnt) -> Alba_json.Nsm_host.make id info cnt)
          nsm_hosts
      in
      print_result res Alba_json.Nsm_host.t_list_to_yojson
    end else
      Lwt_io.printlf
        "Found %i nsm_hosts: %s"
        cnt
        ([%show: (string * Albamgr_protocol.Protocol.Nsm_host.t * int64) list]
           nsm_hosts)
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_nsm_hosts_cmd =
  Term.(pure alba_list_nsm_hosts
        $ alba_cfg_url
        $ tls_config
        $ to_json
        $ verbose
        $ attempts 1),
  Term.info "list-nsm-hosts" ~doc:"list all nsm hosts"

let alba_add_nsm_host alba_cfg_url tls_config nsm_host_cfg_url to_json verbose attempts =
  let t () =
    let open Albamgr_protocol.Protocol in
    with_albamgr_client
      alba_cfg_url ~attempts tls_config
      (fun client ->
       Alba_arakoon.config_from_url nsm_host_cfg_url >>= fun cfg ->
       let nsm_host_id = cfg.Alba_arakoon.Config.cluster_id in
         client # add_nsm_host
                ~nsm_host_id
                ~nsm_host_info:Nsm_host.({ kind = (Arakoon cfg); lost = false; }))
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_add_nsm_host_cmd =
  Term.(pure alba_add_nsm_host
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & pos 0 (some url_converter) None
               & info [] ~docv:"CONFIG_FILE" ~doc:"config url for the nsm host")
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info "add-nsm-host" ~doc:"add a nsm host"

let alba_update_nsm_host
      (alba_cfg_url:Url.t)
      tls_config nsm_host_cfg_url lost to_json verbose attempts
  =
  let t () =
    let open Albamgr_protocol.Protocol in
    with_albamgr_client
      alba_cfg_url ~attempts tls_config
      (fun client ->
       Alba_arakoon.config_from_url nsm_host_cfg_url >>= fun cfg ->
       let nsm_host_id = cfg.Alba_arakoon.Config.cluster_id in
         client # update_nsm_host
                ~nsm_host_id
                ~nsm_host_info:Nsm_host.({ kind = (Arakoon cfg); lost; }))
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_update_nsm_host_cmd =
  Term.(pure alba_update_nsm_host
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required &
               pos 0 (some url_converter) None &
               info [] ~docv:"CONFIG_FILE" ~doc:"config file for the nsm host")
        $ Arg.(value &
               flag &
               info ["lost"] ~doc:"optionally mark the nsm host as lost (so it will not be used for new namespaces)")
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info "update-nsm-host" ~doc:"update a nsm host"

let alba_mgr_get_version
      cfg_file tls_config
      to_json verbose attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       client # get_version >>= version_result to_json
      )
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_mgr_get_version_cmd =
  Term.(pure alba_mgr_get_version
        $ alba_cfg_url
        $ tls_config
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info
    "mgr-get-version"
    ~doc:"the alba mgr's version info"

let alba_mgr_statistics cfg_file tls_config attempts clear verbose =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       client # statistics clear >>= fun statistics ->
       Lwt_io.printlf "%s" (Albamgr_plugin.Statistics.show statistics)
      )
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_mgr_statistics_cmd =
  Term.(pure alba_mgr_statistics
        $ alba_cfg_url
        $ tls_config
        $ attempts 1
        $ clear
        $ verbose
  ),
  Term.info
    "mgr-statistics"
    ~doc:"the alba mgr's statistics"

let alba_list_decommissioning_osds
      cfg_file tls_config to_json verbose attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
         client # list_all_decommissioning_osds >>= fun (cnt, osds) ->
         let open Albamgr_protocol.Protocol in
         if to_json
         then
           client # get_alba_id >>= fun alba_id ->
           let res =
             List.map
               (fun (osd_id, info) ->
                  Alba_json.Osd.make
                    alba_id
                    (Osd.ClaimInfo.ThisAlba osd_id)
                    info)
               osds
           in
           print_result res Alba_json.Osd.t_list_to_yojson
         else
           Lwt_log.info_f "%i osds still decommissioning: %s"
             cnt
             ([%show : (Osd.id * Nsm_model.OsdInfo.t) list] osds))
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_decommissioning_osds_cmd =
  Term.(pure alba_list_decommissioning_osds
        $ alba_cfg_url
        $ tls_config
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info
    "list-decommissioning-osds"
    ~doc:"list osds that are not yet fully decommissioned"


let alba_list_purging_osds
      cfg_file tls_config to_json verbose attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
         client # list_all_purging_osds >>= fun (cnt, osds) ->
         let open Albamgr_protocol.Protocol in
         Lwt_list.map_s
           (fun osd_id ->
              client # get_osd_by_osd_id ~osd_id >>= function
              | None -> Lwt.return None
              | Some osd_info -> Lwt.return (Some (osd_id, osd_info)))
           osds >>= fun osds ->
         let osds = List.map_filter Std.id osds in
         if to_json
         then
           client # get_alba_id >>= fun alba_id ->
           let res =
             List.map
               (fun (osd_id, info) ->
                 Alba_json.Osd.make
                   alba_id
                   (Osd.ClaimInfo.ThisAlba osd_id)
                   info)
               osds
           in
           print_result res Alba_json.Osd.t_list_to_yojson
         else
           Lwt_log.info_f "%i osds still decommissioning: %s"
             cnt
             ([%show : (Osd.id * Nsm_model.OsdInfo.t) list] osds))
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_purging_osds_cmd =
  Term.(pure alba_list_purging_osds
        $ alba_cfg_url
        $ tls_config
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info
    "list-purging-osds"
    ~doc:"list osds that are not yet fully purged"


let alba_list_participants cfg_file tls_config prefix verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file tls_config
      ~attempts
      (fun client ->
       client # get_participants ~prefix >>= fun (cnt, participants) ->
       Lwt_log.info_f
         "Found %i participants:\n%s"
         cnt
         ([%show : (string*int) list] participants))
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_list_participants_cmd =
  let prefix = Arg.(required
               & pos 0 (some string) None
               & info [] ~docv:"PREFIX" ~doc:"prefix")
  in
  Term.(pure alba_list_participants
        $ alba_cfg_url
        $ tls_config
        $ prefix
        $ verbose
        $ attempts 1
  ),
  Term.info
    "list-participants"
    ~doc:"list participants"


let alba_list_work cfg_file tls_config
                   first finc last max
                   to_json verbose attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
        let first = match first with
          | "" -> 0L
          | s -> Int64.of_string first
        and last = Option.map (fun x -> Int64.of_string x, true) last
        in
        let batch_size = 10_000 in
        let max = if max = -1 then max_int else max in
        let rec loop acc first finc more cnt =
          match (more, cnt) with
          | (false, _ ) -> Lwt.return ((cnt, acc), false)
          | (true, cnt) ->
             if cnt = max then Lwt.return ((cnt, acc), true)
             else
               begin
                 let todo = max - cnt in
                 let batch =
                   if todo > batch_size
                   then batch_size
                   else todo
                 in
                 Lwt_log.info_f
                   "cnt = %06i todo=%06i fetching at most %06i from %Li"
                   cnt todo batch first
                 >>= fun () ->
                 client # get_work
                        ~first ~finc ~last ~max:batch
                        ~reverse:false
                 >>= fun ((ccnt, cr), more') ->
                 let acc' =  cr :: acc in
                 let cnt' = cnt + ccnt in
                 let first' =
                   match List.last cr with
                   | Some x -> fst x
                   | None -> assert (more' = false); 0L
                 and finc' = false
                 in
                 loop acc' first' finc' more' cnt'
               end
        in
        loop [] first finc true 0
        >>= fun ((cnt, r0),more) ->
        let r = List.fold_left (fun acc r -> r @ acc ) [] r0
        in
        if to_json
        then
          print_result cnt (fun c -> `Assoc [ "count", `Int c ])
        else
          begin
            Lwt_io.printlf "received %i items\n" cnt >>= fun () ->
            Lwt_io.printlf "    id   | item " >>= fun () ->
            Lwt_io.printlf "---------+------" >>= fun () ->
            Lwt_list.iter_s
              (fun (id, item) ->
                Lwt_io.printlf "%8Li | %S" id ([%show : Albamgr_protocol.Protocol.Work.t] item)
              ) r
            >>= fun () ->
            if more
            then Lwt_io.printl "..."
            else Lwt.return ()
          end
      )
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_work_cmd =
  Term.(pure alba_list_work
        $ alba_cfg_url
        $ tls_config
        $ first $finc $ last $ max
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "list-work"
    ~doc:"list outstanding work items"


let alba_list_jobs cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
        let first = ""
        and finc = true
        and last = None
        and max = -1
        in
        client # list_jobs ~first ~finc ~last ~max ~reverse:false
        >>= fun ((cnt,r),more) ->
        if to_json
        then
          print_result r Alba_json.string_list_to_json
        else
          Lwt_list.iter_s
            (fun x -> Lwt_io.printlf "%S" x)
            r
      )
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_list_jobs_cmd =
  Term.(pure alba_list_jobs
        $ alba_cfg_url
        $ tls_config
        $ to_json $ verbose
        $ attempts 1
  ),
  Term.info
    "list-jobs"
    ~doc:"list job names"

let alba_mark_work_items_completed cfg_file tls_config work_ids verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
        Lwt_list.iter_s
          (fun work_id ->
            Lwt.catch
              (fun () -> client # mark_work_completed ~work_id)
              (fun exn -> Lwt_log.info_f ~exn "Exception while marking item %Li as completed" work_id))
          work_ids)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_mark_work_items_completed_cmd =
  Term.(pure alba_mark_work_items_completed
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & pos 0 (some (list int64)) None
               & info []
                      ~docv:"WORK_IDS"
                      ~doc:"list of work ids")
        $ verbose
        $ attempts 1
  ),
  Term.info
    "dev-mark-work-items-completed"
    ~doc:"for dev/testing purposes only: mark work items as completed"


let alba_bump_next_work_item_id cfg_file tls_config id verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client -> client # bump_next_work_item_id id)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_bump_next_work_item_id_cmd =
  Term.(pure alba_bump_next_work_item_id
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & pos 0 (some int64) None
               & info [] ~docv:"WORK_ID" ~doc:"work_id")
        $ verbose
        $ attempts 1),
  Term.info
    "dev-bump-next-work-item-id"
    ~doc:"dev/testing purposes only"

let alba_bump_next_osd_id cfg_file tls_config id verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client -> client # bump_next_osd_id id)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_bump_next_osd_id_cmd =
  Term.(pure alba_bump_next_osd_id
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & pos 0 (some int64) None
               & info [] ~docv:"OSD_ID" ~doc:"osd_id")
        $ verbose
        $ attempts 1),
  Term.info
    "dev-bump-next-osd-id"
    ~doc:"dev/testing purposes only"

let alba_bump_next_namespace_id cfg_file tls_config id verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client -> client # bump_next_namespace_id id)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_bump_next_namespace_id_cmd =
  Term.(pure alba_bump_next_namespace_id
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & pos 0 (some int64) None
               & info [] ~docv:"NAMESPACE_ID" ~doc:"namespace_id")
        $ verbose
        $ attempts 1),
  Term.info
    "dev-bump-next-namespace-id"
    ~doc:"dev/testing purposes only"


let alba_add_iter_namespace_item
      cfg_file tls_config namespace name factor action
      ~to_json ~verbose ~attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       client # get_namespace ~namespace >>= function
       | None -> Lwt.fail_with ""
       | Some (_, namespace_info) ->
          let open Albamgr_protocol.Protocol in
          let namespace_id = namespace_info.Namespace.id in
          client # add_work_items
                 [ Work.(IterNamespace
                           (action,
                            namespace_id,
                            name,
                            factor)) ])
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_rewrite_namespace cfg_file tls_arg namespace name factor to_json verbose attempts =
  alba_add_iter_namespace_item
    cfg_file tls_arg namespace name factor
    Albamgr_protocol.Protocol.Work.Rewrite
    ~to_json ~verbose ~attempts

let job_name p =
  Arg.(required
       & pos p (some string) None
       & info []
              ~docv:"JOB_NAME"
              ~doc:"name of the job to be added. it should be unique. can be used with show-job-progress / clear-job-progress")

let factor x =
  Arg.(value
       & opt int x
       & info ["factor"] ~doc:"specifies into how many pieces the job should be divided")
let alba_rewrite_namespace_cmd =
  Term.(pure alba_rewrite_namespace
        $ alba_cfg_url
        $ tls_config
        $ namespace 0
        $ job_name 1
        $ factor 1
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "rewrite-namespace"
    ~doc:"rewrite all objects in the specified namespace"


let no_verify_checksum =
  Arg.(value
       & flag
       & info
           ["no-verify-checksum"]
           ~doc:"flag to specify checksums should not be verified")

let no_repair_osd_unavailable =
  Arg.(value
       & flag
       & info
           ["no-repair-osd-unavailable"]
           ~doc:"flag to specify that fragments on unavailable osds should not be repaired")

let alba_verify_namespace
      cfg_file tls_config namespace name factor
      no_verify_checksum no_repair_osd_unavailable
      to_json verbose attempts
  =
  alba_add_iter_namespace_item
    cfg_file tls_config namespace name factor
    (let open Albamgr_protocol.Protocol.Work in
     Verify { checksum = not no_verify_checksum;
              repair_osd_unavailable = not no_repair_osd_unavailable; })
    ~to_json ~verbose ~attempts

let alba_verify_namespace_cmd =
  Term.(pure alba_verify_namespace
        $ alba_cfg_url
        $ tls_config
        $ namespace 0
        $ job_name 1
        $ factor 1
        $ no_verify_checksum
        $ no_repair_osd_unavailable
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "verify-namespace"
    ~doc:"verify all objects in the specified namespace"


let alba_verify_namespaces
      cfg_file tls_config
      (ns_names: (string * string) list)
      factor
      no_verify_checksum no_repair_osd_unavailable
      to_json verbose attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
        client # list_all_namespaces >>= fun (_,ns_infos) ->
        let ns_info_map =
          List.fold_left
            (fun acc (name,info) -> StringMap.add name info acc)
            StringMap.empty ns_infos
        in
        let work_items =
          List.map
            (fun (ns_name,job_name) ->
              let namespace_info =
                try StringMap.find ns_name ns_info_map
                with
                | Not_found -> failwith (Printf.sprintf "%s not found" ns_name)
              in
              let open Albamgr_protocol.Protocol in
              let namespace_id = namespace_info.Namespace.id in
              let action =
                Work.Verify {
                    Work.checksum = not no_verify_checksum;
                    Work.repair_osd_unavailable = not no_repair_osd_unavailable;
                  }
              in
              Work.(IterNamespace
                      (action, namespace_id, job_name, factor))
            )
            ns_names
        in
        client # add_work_items work_items
      )
  in
  lwt_cmd_line ~to_json ~verbose t



let alba_verify_namespaces_cmd =
  let ns_names =
    Arg.(required
         & opt (some (list ~sep:';' (pair ~sep:',' string string))) None
         & info
             ["namespaces"]
             ~doc:"for example: \"ns1,job1;ns2,job2\" will add 2 jobs"
             ~docv:"[(namespace, job_name)]"
    )
  in
  Term.(pure alba_verify_namespaces
        $ alba_cfg_url $ tls_config
        $ ns_names
        $ factor 1
        $ no_verify_checksum $ no_repair_osd_unavailable
        $ to_json
        $ verbose $ attempts 1),
  Term.info
    "verify-namespaces"
    ~doc:"add more verify namespace jobs at once"

let alba_show_job_progress cfg_file tls_config name to_json verbose =
  let t () =
    with_albamgr_client
      cfg_file ~attempts:1 tls_config
      (fun client ->
        client # get_progress_for_prefix name >>= fun (_, progresses) ->
        if to_json
        then
          let to_yojson p = Alba_json.Progress.progresses_to_yojson p in
          print_result progresses to_yojson
        else
          Lwt_list.iter_s
            (fun (id, p) ->
              Lwt_log.info_f
                "%i: %s"
                id
                ([%show : Albamgr_protocol.Protocol.Progress.t] p))
            progresses)
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_show_job_progress_cmd =
  Term.(pure alba_show_job_progress
        $ alba_cfg_url
        $ tls_config
        $ job_name 0
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "show-job-progress"
    ~doc:"show progress of a certain job"

let alba_clear_job_progress cfg_file tls_config name to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
        client # get_progress_for_prefix name >>= fun (cnt, progresses) ->
        Lwt_list.iter_s
          (fun (i, p) ->
            let name = serialize (Llio.pair_to
                                    Llio.raw_string_to
                                    Llio.int_to)
                                 (name, i)
            in
            client # update_progress name p None)
          progresses)
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_clear_job_progress_cmd =
  Term.(pure alba_clear_job_progress
        $ alba_cfg_url
        $ tls_config
        $ job_name 0
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info
    "clear-job-progress"
    ~doc:"clear progress of a certain job"

let alba_get_maintenance_config cfg_file tls_config to_json verbose attempts =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       client # get_maintenance_config >>= fun cfg ->
       if to_json
       then
         print_result cfg Maintenance_config.to_yojson
       else
         Lwt_io.printlf
           "Maintenance config = %s"
           (Maintenance_config.show cfg))
  in
  lwt_cmd_line ~to_json ~verbose t

let alba_get_maintenance_config_cmd =
  Term.(pure alba_get_maintenance_config
        $ alba_cfg_url
        $ tls_config
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info "get-maintenance-config" ~doc:"get the maintenance config from the albamgr"

let alba_update_maintenance_config
      cfg_file tls_config
      enable_auto_repair'
      auto_repair_timeout_seconds'
      auto_repair_add_disabled_nodes
      auto_repair_remove_disabled_nodes
      enable_rebalance'
      add_cache_eviction_prefix_preset_pairs
      remove_cache_eviction_prefix_preset_pairs
      redis_lru_cache_eviction'
      to_json
      verbose
      attempts
  =
  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->
       client # update_maintenance_config
              Maintenance_config.Update.(
         { enable_auto_repair';
           auto_repair_timeout_seconds';
           auto_repair_add_disabled_nodes;
           auto_repair_remove_disabled_nodes;
           enable_rebalance';
           add_cache_eviction_prefix_preset_pairs;
           remove_cache_eviction_prefix_preset_pairs;
           redis_lru_cache_eviction';
         }) >>= fun maintenance_config ->
       if to_json
       then Lwt.return ()
       else Lwt_io.printlf
              "Maintenance config now is %s"
              (Maintenance_config.show maintenance_config))
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_update_maintenance_config_cmd =
  Term.(pure alba_update_maintenance_config
        $ alba_cfg_url
        $ tls_config
        $ Arg.(value
               & vflag None
                       [ (Some true,
                          info ["enable-auto-repair"]);
                         (Some false,
                          info ["disable-auto-repair"]); ])
        $ Arg.(value
               & opt (some float) None
               & info ["auto-repair-timeout-seconds"])
        $ Arg.(value
               & opt_all string []
               & info ["auto-repair-add-disabled-node"])
        $ Arg.(value
               & opt_all string []
               & info ["auto-repair-remove-disabled-node"])
        $ Arg.(value
               & vflag None
                       [ (Some true,
                          info ["enable-rebalance"]);
                         (Some false,
                          info ["disable-rebalance"]); ])
        $ Arg.(value
               & opt_all (pair string string) []
               & info ["add-cache-eviction"]
                      ~doc:"add a prefix,preset for cache eviction")
        $ Arg.(value
               & opt_all string []
               & info ["remove-cache-eviction"]
                      ~doc:"remove a prefix for cache eviction")
        $ Arg.(
          let converter : Maintenance_config.redis_lru_cache_eviction Arg.converter =
            let parser s =
              try
                let uri = Uri.of_string s in
                assert (Uri.scheme uri = Some "redis");
                `Ok Maintenance_config.(
                  { host = Uri.host uri |> Option.get_some;
                    port = Uri.port uri |> Option.get_some;
                    key = Str.string_after (Uri.path uri) 1;
                  })
              with exn ->
                `Error (Printexc.get_backtrace ())
            in
            let printer fmt s =
              Format.pp_print_string
                fmt
                (Maintenance_config.show_redis_lru_cache_eviction s)
            in
            parser, printer
          in
          value
               & opt (some converter) None
               & info ["set-lru-cache-eviction"]
                      ~doc:"set lru cache eviction parameters (e.g. redis://127.0.0.1:6379/key_for_sorted_set)")
        $ to_json
        $ verbose
        $ attempts 1
  ),
  Term.info "update-maintenance-config" ~doc:"update the maintenance config"

let alba_get_abm_client_config cfg_file tls_config allow_dirty verbose attempts =
  let t () =
    begin
      if allow_dirty
      then
        begin
          Alba_arakoon.config_from_url cfg_file >>= fun cfg ->
          let open Albamgr_client in
          retrieve_cfg_from_any_node
            ~tls_config
            cfg
          >>= function
          | Retry -> Lwt.fail_with "could not fetch abm client config from any of the nodes"
          | Res cfg -> Lwt.return cfg
        end
      else
        with_albamgr_client
          cfg_file ~attempts tls_config
          (fun client ->
           client # get_client_config)
    end >>= fun ccfg ->
    Lwt_log.info_f "Get client config: %s" (Alba_arakoon.Config.show ccfg)
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_get_abm_client_config_cmd =
  Term.(pure alba_get_abm_client_config
        $ alba_cfg_url
        $ tls_config
        $ Arg.(value
               & flag
               & info ["allow-dirty"] ~doc:"allow fetching the config from a non slave node")
        $ verbose
        $ attempts 1
  ),
  Term.info "get-abm-client-config"

let alba_update_abm_client_config cfg_url tls_config to_json verbose attempts =
  let t () =
    Alba_arakoon.config_from_url cfg_url >>= fun cfg ->
    with_albamgr_client
      cfg_url ~attempts tls_config
      (fun client ->
       client # store_client_config cfg)
  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_update_abm_client_config_cmd =
  Term.(pure alba_update_abm_client_config
        $ alba_cfg_url
        $ tls_config
        $ to_json
        $ verbose
        $ attempts 1),
  Term.info "update-abm-client-config"


let alba_delete_fragment
      cfg_file tls_config verbose
      namespace object_name chunk_id fragment_id immediate_repair
  =
  let t () =
    with_alba_client
      cfg_file tls_config
      (fun alba_client ->
        alba_client # mgr_access # get_namespace ~namespace
        >>= fun nso ->
        match nso with
        | None -> Lwt_io.printlf "namespace %S not found" namespace
        | Some (x,ns) ->
           let namespace_id =
             let open Albamgr_protocol.Protocol in
             ns.Namespace.id
           in
           begin
             alba_client # get_object_manifest ~namespace ~object_name
                         ~consistent_read:true ~should_cache:false
             >>=fun (hm,r) ->
             begin
               match r with
               | None -> Lwt.fail_with "object not found"
               | Some mf ->
                  let open Nsm_model in
                  let floc = Manifest.get_location mf chunk_id fragment_id in
                  let object_id = mf.Manifest.object_id in
                  begin
                    match floc with
                    | (None,_) -> Lwt.fail_with "no such fragment"
                    | (Some osd_id, version) ->
                       Lwt_log.debug_f "osd_id:%Li version:%i" osd_id version
                       >>= fun () ->
                       Alba_test.delete_fragment
                         alba_client
                         namespace_id
                         object_id
                         (osd_id, version)
                         chunk_id fragment_id
                       >>= fun () ->
                       if immediate_repair
                       then
                         Alba_test.with_maintenance_client
                           alba_client
                           (fun mc ->
                             mc # repair_object ~namespace_id ~manifest:mf
                            ~problem_fragments:[(chunk_id, fragment_id)]
                           )
                       else Lwt.return_unit
                  end
             end

           end
      )
  in
  lwt_cmd_line ~to_json:false ~verbose t


let alba_delete_fragment_cmd =
  let chunk_id =
    Arg.(required
         & opt (some int) None
         & info ["chunk"] ~docv:"target chunk of the object"
    )
  in
  let fragment_id =
    Arg.(required
         & opt (some int) None
         & info ["fragment"] ~docv:"target fragment of the chunk"
    )
  in
  let immediate_repair =
    Arg.(value
         & flag
         & info ["immediate-repair"] ~doc:"repair now"
    )
  in
  Term.(pure alba_delete_fragment
        $ alba_cfg_url
        $ tls_config
        $ verbose
        $ namespace 0
        $ object_name_upload 1
        $ chunk_id
        $ fragment_id
        $ immediate_repair
  ),
  Term.info "dev-delete-fragment" ~doc:"remove a fragment of an object"


let alba_get_presets_propagation_state
      cfg_file tls_config
      preset_names
      include_all_presets
      verbose
      attempts
  =
  let t () =
    with_albamgr_client
      cfg_file tls_config
      ~attempts
      (fun client ->
        (if include_all_presets
         then client # list_all_presets ()
              >|= snd
              >|= List.map (fun (name, _, _, _) -> name)
         else Lwt.return preset_names)
        >>= fun preset_names ->

        client # get_presets_propagation_state ~preset_names >>= fun prop_states ->

        Lwt_log.info_f "prop_states = %s" ([%show : Preset.Propagation.t option list] prop_states)
      )
  in
  lwt_cmd_line ~to_json:false ~verbose t

let alba_get_presets_propagation_state_cmd =
  Term.(pure alba_get_presets_propagation_state
        $ alba_cfg_url
        $ tls_config
        $ Arg.(value
               & opt (list string) []
               & info [ "preset" ] ~docv:"PRESET" ~doc:"specify one or more presets")
        $ Arg.(value
               & flag
               & info [ "all-presets" ] ~doc:"for all presets")
        $ verbose
        $ attempts 1
  ),
  Term.info "get-presets-propagation-state" ~doc:"gets the preset propagation state"

let alba_add_propagate_preset
      cfg_file tls_config
      preset_name
      to_json
      verbose
      attempts
  =
  let t () =
    with_albamgr_client
      cfg_file tls_config ~attempts
      (fun client ->
        let open Albamgr_protocol.Protocol in
        let item = Work.PropagatePreset preset_name in
        client # add_work_items [item]
        >>= fun () ->
        Lwt.return_unit
      )

  in
  lwt_cmd_line_unit ~to_json ~verbose t

let alba_add_propagate_preset_cmd =
  Term.(pure alba_add_propagate_preset
        $ alba_cfg_url
        $ tls_config
        $ Arg.(required
               & opt (some string) None
               & info ["preset"] ~docv:"PRESET"
          )
        $ to_json
        $ verbose
        $ attempts 1

  ),
  Term.info "dev-add-propagate-preset" ~doc:"create preset propagation work"


let cmds = [
    alba_list_namespaces_cmd;
    alba_list_namespaces_by_id_cmd;

    recover_namespace_cmd;
    alba_mgr_get_version_cmd;

    alba_list_osds_cmd;
    alba_list_all_osds_cmd;
    alba_list_available_osds_cmd;
    alba_list_decommissioning_osds_cmd;
    alba_list_purging_osds_cmd;

    alba_add_nsm_host_cmd;
    alba_update_nsm_host_cmd;
    alba_list_nsm_hosts_cmd;

    alba_mgr_statistics_cmd;

    alba_list_participants_cmd;
    alba_list_work_cmd;
    alba_list_jobs_cmd;
    alba_mark_work_items_completed_cmd;

    alba_rewrite_namespace_cmd;
    alba_verify_namespace_cmd;
    alba_verify_namespaces_cmd;
    alba_show_job_progress_cmd;
    alba_clear_job_progress_cmd;

    alba_get_maintenance_config_cmd;
    alba_update_maintenance_config_cmd;

    alba_get_abm_client_config_cmd;
    alba_update_abm_client_config_cmd;

    alba_bump_next_work_item_id_cmd;
    alba_bump_next_osd_id_cmd;
    alba_bump_next_namespace_id_cmd;
    alba_delete_fragment_cmd;

    alba_get_presets_propagation_state_cmd;
    alba_add_propagate_preset_cmd;
  ]
