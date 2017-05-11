(*
Copyright (C) 2016 iNuron NV

This file is part of Open vStorage Open Source Edition (OSE), as available from


    http://www.openvstorage.org and
    http://www.openvstorage.com.

This file is free software; you can redistribute it and/or modify it
under the terms of the GNU Affero General Public License v3 (GNU AGPLv3)
as published by the Free Software Foundation, in version 3 as it comes
in the <LICENSE.txt> file of the Open vStorage OSE distribution.

Open vStorage is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY of any kind.
*)

open! Prelude
open Cli_common
open Lwt.Infix
open Cmdliner
open Albamgr_protocol


let accumulate
    : type dest msg. (dest, msg) Protocol.Msg_log.t
           -> Albamgr_client.client
           -> dest list
           -> (dest * Protocol.Msg_log.id * msg) list Lwt.t
  = fun typ client destinations ->

  Lwt_list.fold_left_s
    (fun acc destination ->
     client # get_next_msgs typ destination >>= fun ((_,xs),_more) ->
     let xs' = List.map (fun (msg_id, msg) -> (destination,msg_id,msg)) xs in
     Lwt.return (acc @ xs')
    ) [] destinations

let transform_osd (client:Albamgr_client.client) = function
  | [] ->
     client # list_all_claimed_osds >>= fun (c,osd_infos ) ->
     let r =
       List.map
         (fun ((x : int64),_ ) -> x)
         osd_infos
     in
     Lwt.return r
  | x -> Lwt.return x

let transform_nsm (client:Albamgr_client.client)  = function
  | [] ->
     begin
       client # list_all_nsm_hosts () >>= fun (c, nsm_hosts ) ->
       let r =
         List.map
           (fun (id,h,_) ->
            id
           )
           nsm_hosts
       in
       Lwt.return r
     end
  | (x : string list) -> Lwt.return x


let list_nsm_host_messages cfg_url tls_config attempts (destinations: string list) =

  let t () =
    with_albamgr_client
      cfg_url tls_config ~attempts
      (fun client ->
       transform_nsm client destinations >>= fun destinations' ->
       accumulate Protocol.Msg_log.Nsm_host client destinations' >>= fun xs ->

       Lwt_io.printlf "   nsm_host    | msg_id | message" >>= fun () ->
       Lwt_io.printlf "---------------+--------+--------" >>= fun () ->
       Lwt_list.iter_s
         (fun (destination, msg_id,msg) ->
          Lwt_io.printlf
            "%20s |%7Li | %s"
            destination msg_id ([%show: Nsm_host_protocol.Protocol.Message.t] msg)>>= fun () ->
          Lwt.return ()
         ) xs
      )
  in
  lwt_cmd_line ~to_json:false ~verbose:false t

let list_nsm_host_messages_cmd =
  let nsm_hosts =
    let doc = "a comma separated list of the names of the nsm hosts, empty means \"`em all\"" in
    Arg.(value
         & opt (list string) []
         & info ["nsm-hosts"] ~docv:"NSM_HOSTS" ~doc
    )
  in
  Term.(pure list_nsm_host_messages
        $ alba_cfg_url
        $ tls_config
        $ attempts 1
        $ nsm_hosts),
  Term.(info "list-nsm-host-messages" ~doc:"list messages from mgr to nsm hosts")

let list_osd_messages cfg_file tls_config attempts (destinations:int64 list) verbose =

  let t () =
    with_albamgr_client
      cfg_file ~attempts tls_config
      (fun client ->

       transform_osd client destinations >>= fun destinations' ->
       accumulate Protocol.Msg_log.Osd client destinations' >>= fun xs ->

       Lwt_io.printlf "   osd  | msg_id | message" >>= fun () ->
       Lwt_io.printlf "--------+--------+--------" >>= fun () ->
       Lwt_list.iter_s
         (fun (destination, msg_id,msg) ->
          Lwt_io.printlf
            "%11Li |%7Li | %s"
            destination msg_id ([%show: Protocol.Osd.Message.t] msg)>>= fun () ->
          Lwt.return ()
         ) xs
      )
  in
  lwt_cmd_line ~to_json:false ~verbose t

let list_osd_messages_cmd =
  let destinations  =
    let doc = "a comma seperated list of the names of the osd-ids, empty means \"`em all\""
    in
    Arg.(value
         & opt (list ~sep:',' int64) []
         & info ["osd-ids"] ~docv:"OSD-IDS" ~doc
    )
  in
  Term.(pure list_osd_messages
        $ alba_cfg_url
        $ tls_config
        $ attempts 1
        $ destinations
        $ verbose),
  Term.(info "list-osd-messages" ~doc:"list messages from mgr to osds")

let cmds =[
    list_osd_messages_cmd;
    list_nsm_host_messages_cmd;
  ]
