(*
Copyright 2015 iNuron NV

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*)

let get_some = function
  | Some x -> x
  | None -> failwith "get_some"

module Config = struct
  let env_or_default x y =
    try
      Sys.getenv x
    with Not_found -> y

  type t = {
      home : string;
      workspace : string;
      arakoon_home: string;
      arakoon_bin : string;
      arakoon_189_bin: string;
      arakoon_path : string;
      abm_nodes : string list;
      abm_path : string;

      alba_home : string;
      alba_base_path : string;
      alba_bin : string;
      alba_plugin_path : string;
      alba_06_bin : string;
      alba_06_plugin_path :string;
      license_file : string;
      tls : bool;

      local_nodeid_prefix : string;
      n_osds : int;

      monitoring_file : string ;

      voldrv_test : string;
      voldrv_backend_test : string;
      failure_tester : string;
    }

  let make () =
    let home = Sys.getenv "HOME" in
    let workspace = env_or_default "WORKSPACE" "" in
    let arakoon_home = env_or_default "ARAKOON_HOME" (home ^ "/workspace/ARAKOON/arakoon") in
    let arakoon_bin = env_or_default "ARAKOON_BIN" (arakoon_home ^ "/arakoon.native") in
    let arakoon_189_bin = env_or_default "ARAKOON_189_BIN" "/usr/bin/arakoon" in
    let arakoon_path = workspace ^ "/tmp/arakoon" in

    let abm_nodes = ["abm_0";"abm_1";"abm_2"] in

    let abm_path = arakoon_path ^ "/" ^ "abm" in

    let alba_home = env_or_default "ALBA_HOME" workspace in
    let alba_base_path = workspace ^ "/tmp/alba" in

    let alba_bin    = env_or_default "ALBA_BIN" (alba_home  ^ "/ocaml/alba.native") in
    let alba_plugin_path = env_or_default "ALBA_PLUGIN_HOME" (alba_home ^ "/ocaml") in
    let alba_06_bin = env_or_default "ALBA_06"  "/usr/bin/alba" in
    let alba_06_plugin_path = env_or_default "ALBA_06_PLUGIN_PATH" "/usr/lib/alba" in
    let license_file = alba_home ^ "/bin/0.6/community_license" in
    let failure_tester = alba_home ^ "/ocaml/disk_failure_tests.native" in

    let monitoring_file = workspace ^ "/tmp/alba/monitor.txt" in

    let local_nodeid_prefix = Printf.sprintf "%08x" (Random.bits ()) in
    let asd_path_t = env_or_default "ALBA_ASD_PATH_T" (alba_base_path ^ "/asd/%02i") in

    let voldrv_test = env_or_default
                      "VOLDRV_TEST"
                      (home ^ "/workspace/VOLDRV/volumedriver_test") in
    let voldrv_backend_test = env_or_default
                              "VOLDRV_BACKEND_TEST"
                              (home ^ "/workspace/VOLDRV/backend_test") in
    let n_osds = 12 in

    let tls =
      let v = env_or_default "ALBA_TLS" "false" in
      Scanf.sscanf v "%b" (fun x -> x)
    in
    {
      home;
      workspace;
      arakoon_home;
      arakoon_bin;
      arakoon_189_bin;
      arakoon_path;
      abm_nodes;
      abm_path;

      alba_home;
      alba_base_path;
      alba_bin;
      alba_plugin_path;
      alba_06_bin;
      alba_06_plugin_path;
      license_file;
      tls;
      local_nodeid_prefix;
      n_osds;

      monitoring_file;

      voldrv_test;
      voldrv_backend_test;
      failure_tester;
    }

  let default = make ()

  let generate_serial =
    let serial = ref 0 in
    fun () ->
       let r = !serial in
       let () = incr serial in
       Printf.sprintf "%i" r


end

module Shell = struct
  let cmd ?(ignore_rc=false) x =
    Printf.printf "%s\n%!" x;
    let rc = x |> Sys.command in
    if not ignore_rc && rc <> 0
    then failwith (Printf.sprintf "%S=x => rc=%i" x rc)
    else ()

  let cmd_with_capture cmd =
    let line = String.concat " " cmd in
    Printf.printf "%s\n" line;
    let open Unix in
    let ic = open_process_in line in
    let read_line () =
      try
        Some (input_line ic)
      with End_of_file -> None
    in
    let rec loop acc =
      match read_line() with
      | None      -> String.concat "\n" (List.rev acc)
      | Some line -> loop (line :: acc)
    in
    let result = loop [] in
    let status = close_process_in ic in
    match status with
    | WEXITED rc ->
       if rc = 0 then result
       else failwith "bad_rc"
    | WSIGNALED signal -> failwith "signal?"
    | WSTOPPED x -> failwith "stopped?"

  let cat f = cmd_with_capture ["cat" ; f]

  let detach ?(out = "/dev/null") inner =
    let x = [
        "nohup";
        String.concat " " inner;
        ">> " ^ out;
        "2>&1";
        "&"
      ]
    in
    String.concat " " x |> cmd

  let cp src tgt = Printf.sprintf "cp %s %s" src tgt |> cmd
end

open Config

let make_ca (cfg:Config.t) =
  let arakoon_path = cfg.arakoon_path in
  let cacert_req = arakoon_path ^ "/cacert-req.pem" in
  Printf.printf "make %s\n%!" cacert_req ;
  let key = arakoon_path ^ "/cacert.key" in

  let subject = "'/C=BE/ST=Vl-Br/L=Leuven/O=openvstorage.com/OU=AlbaTest/CN=AlbaTest CA'" in
  ["openssl"; "req";"-new"; "-nodes";
   "-out";    cacert_req;
   "-keyout"; key;
   "-subj"; subject;
  ]
  |> String.concat " "
  |> Shell.cmd;


  Printf.printf "self sign \n%!" ;
  (* Self sign CA CSR *)
  let cacert = arakoon_path ^ "/cacert.pem" in
  ["openssl";"x509";
   "-signkey"; key;
   "-req"; "-in"  ; cacert_req;
   "-out" ; cacert;
  ] |> String.concat " " |> Shell.cmd;

  "rm " ^ cacert_req |> Shell.cmd

let make_cert ?(cfg=Config.default) path name =
  let subject =
    Printf.sprintf "'/C=BE/ST=Vl-BR/L=Leuven/O=openvstorage.com/OU=AlbaTest/CN=%s'"
                   name
  in
  (* req *)
  let req = Printf.sprintf "%s/%s-req.pem" path name in
  let key = Printf.sprintf "%s/%s.key" path name in
  ["openssl";"req";
   "-out"; req;
   "-new"; "-nodes";
   "-keyout"; key;
   "-subj" ; subject;
  ] |> String.concat " " |> Shell.cmd;

  (* sign *)
  let arakoon_path = cfg.arakoon_path in
  let cacert = arakoon_path ^ "/cacert.pem" in
  let name_pem = Printf.sprintf "%s/%s.pem" path name in
  ["openssl"; "x509"; "-req"; "-in" ; req;
   "-CA"; cacert;
   "-CAkey"; arakoon_path ^ "/cacert.key";
   "-out"; name_pem;
   "-CAcreateserial";"-CAserial" ; arakoon_path ^ "/cacert-serial.seq"
  ] |> String.concat " " |> Shell.cmd;

  "rm " ^ req |> Shell.cmd;

  (* verify *)
  ["openssl"; "verify";
   "-CAfile"; cacert;
   name_pem
  ] |> String.concat " " |> Shell.cmd


let _arakoon_cmd_line ?(cfg=Config.default) x =
  String.concat " " (cfg.arakoon_bin :: x) |> Shell.cmd

let _get_client_tls ?(cfg=Config.default) ()=
  let arakoon_path = cfg.arakoon_path in
  let cacert = arakoon_path ^ "/cacert.pem" in
  let pem    = arakoon_path ^ "/my_client/my_client.pem" in
  let key    = arakoon_path ^ "/my_client/my_client.key" in
  (cacert,pem,key)

class arakoon ?(cfg=Config.default) cluster_id nodes base_port =
  let arakoon_path = cfg.arakoon_path in
  let cluster_path = arakoon_path ^ "/" ^ cluster_id in
  let cfg_file = arakoon_path ^ "/" ^ cluster_id ^ ".ini" in
  let _extend_tls cmd =
    let cacert,my_client_pem,my_client_key = _get_client_tls () in
    cmd @ [
        "-tls-ca-cert"; cacert;
        "-tls-cert"; my_client_pem;
        "-tls-key"; my_client_key;
      ]
  in
  object (self)
    val mutable _binary = cfg.arakoon_bin
    val mutable _plugin_path = cfg.alba_plugin_path

    method to_arakoon_189  =
      _binary <- cfg.arakoon_189_bin;
      _plugin_path <- cfg.alba_06_plugin_path

    method config_file = cfg_file
    method write_node_config_files node =
      let dir_path = cluster_path ^ "/" ^ node in
      "mkdir -p " ^ dir_path |> Shell.cmd;
      Printf.sprintf
        "ln -fs %s/nsm_host_plugin.cmxs %s/nsm_host_plugin.cmxs"
        _plugin_path dir_path |> Shell.cmd;
      Printf.sprintf
        "ln -fs %s/albamgr_plugin.cmxs %s/albamgr_plugin.cmxs"
        _plugin_path dir_path |> Shell.cmd;
      if cfg.tls then make_cert dir_path node

    method write_cluster_config_file =
      let oc = open_out cfg_file in
      let w x = Printf.ksprintf (fun s -> output_string oc s) (x ^^ "\n") in
      w "[global]";
      w "cluster = %s" (String.concat ", " nodes);
      w "cluster_id = %s" cluster_id;
      w "plugins = albamgr_plugin nsm_host_plugin";
      w "";
      if cfg.tls
      then
        begin
          w "tls_ca_cert = %s/cacert.pem" cfg.arakoon_path;
          w "tls_service = true";
          w "tls_service_validate_peer = false";
          w "";
        end;
      List.iteri
        (fun i node ->
         w "[%s]" node;
         w "ip = 127.0.0.1";
         w "client_port = %i" (base_port + i);
         w "messaging_port = %i" (base_port + i + 10);
         let home = cfg.arakoon_path ^ "/" ^ cluster_id ^ "/" ^ node in
         w "home = %s" home;
         w "log_level = debug";
         w "fsync = false";
         w "";
         if cfg.tls then
           begin
             w "tls_cert = %s/%s.pem" home node;
             w "tls_key =  %s/%s.key" home node;
             w "";
           end;

        )
        nodes;
      close_out oc

    method write_config_files =
      List.iter (self # write_node_config_files) nodes;
      self # write_cluster_config_file



    method start_node node =
      [_binary;
       "--node"; node;
       "-config"; cfg_file
      ] |> Shell.detach

    method start =
      List.iter (self # start_node) nodes

    method stop_node name =
      let pid_line = ["pgrep -a arakoon"; "| grep "; name ] |> Shell.cmd_with_capture in
      let pid = Scanf.sscanf pid_line " %i " (fun i -> i) in
      Printf.sprintf "kill %i" pid |> Shell.cmd

    method stop =
      List.iter (self # stop_node) nodes

    method remove_dirs =
      List.iter
        (fun node ->
         let rm = Printf.sprintf "rm -rf %s/%s" cluster_path node in
         let _ = Shell.cmd rm in
         ()
        )
        nodes

    method who_master () : string =
      let line = [cfg.arakoon_bin; "--who-master";"-config"; cfg_file] in
      let line' = if cfg.tls
                  then _extend_tls line
                  else line
      in
      Shell.cmd_with_capture line'

    method wait_for_master ?(max=20) () : string =

      let step () =
        try
          let r = self # who_master () in
          Some r
        with _ -> None
      in
      let rec loop n =
        if n = 0
        then failwith "No_master"
        else
          let mo = step () in
          match mo with
          | None ->
             let () = Printf.printf "%i\n%!" n; Unix.sleep 1 in
             loop (n-1)
          | Some master -> master
      in loop max
end

type tls_client =
  { ca_cert : string;
    creds : string * string;
  } [@@ deriving yojson]

let make_tls_client (cfg:Config.t) =
  if cfg.tls
  then
    let arakoon_path = cfg.arakoon_path in
    let ca_cert = arakoon_path ^ "/cacert.pem" in
    let my_client_pem = arakoon_path ^ "/my_client/my_client.pem" in
    let my_client_key = arakoon_path ^ "/my_client/my_client.key" in
    Some { ca_cert; creds = (my_client_pem, my_client_key)}
  else None

type proxy_cfg =
  { port: int;
    albamgr_cfg_file : string;
    log_level : string;
    fragment_cache_dir : string;
    manifest_cache_size : int;
    fragment_cache_size : int;
    tls_client : tls_client option;
  } [@@deriving yojson]

let make_proxy_config id abm_cfg_file base tls_client=
  { port = 10000 + id;
    albamgr_cfg_file = abm_cfg_file;
    log_level = "debug";
    fragment_cache_dir  = base ^ "/fragment_cache";
    manifest_cache_size = 100 * 1000;
    fragment_cache_size = 100 * 1000 * 1000;
    tls_client;
  }

let _alba_extend_tls ?(cfg=Config.default) cmd =
  let arakoon_path = cfg.arakoon_path in
  let cacert = arakoon_path ^ "/cacert.pem" in
  let my_client_pem = arakoon_path ^ "/my_client/my_client.pem" in
  let my_client_key = arakoon_path ^ "/my_client/my_client.key" in
  cmd @ [Printf.sprintf
           "--tls=%s,%s,%s" cacert my_client_pem my_client_key]

let _alba_cmd_line ?(cfg=Config.default) ?cwd ?(ignore_tls=false) x =
  let maybe_extend_tls cmd =
    if not ignore_tls && cfg.tls
    then
      begin
        _alba_extend_tls cmd
      end
    else cmd
  in
  let cmd = (cfg.alba_bin :: x) in
  let cmd1 = match cwd with
    | Some dir -> "cd":: dir ::"&&":: cmd
    | None -> cmd
  in
  cmd1
  |> maybe_extend_tls
  |> String.concat " "
  |> Shell.cmd ~ignore_rc:false


let suppress_tags tags = function
  | `Assoc xs ->
     let xs' =
       List.filter
         (fun (tag, value ) ->
          not (List.mem tag tags)
          && value <> `Null
         ) xs in
     `Assoc xs'
  | _ -> failwith "unexpected json"

class proxy id cfg alba_bin abm_cfg_file  =
  let proxy_base = Printf.sprintf "%s/proxies/%02i" cfg.alba_base_path id in
  let p_cfg_file = proxy_base ^ "/proxy.cfg" in
  let tls_client = make_tls_client cfg in
  let p_cfg = make_proxy_config id abm_cfg_file proxy_base tls_client in
  object

  method write_config_file :unit =
    "mkdir -p " ^ proxy_base |> Shell.cmd;
    let oc = open_out p_cfg_file in
    let json = proxy_cfg_to_yojson p_cfg in
    let json' = suppress_tags [] json in
    Yojson.Safe.pretty_to_channel oc json' ;
    close_out oc

  method start : unit =
    let out = Printf.sprintf "%s/proxy.out" proxy_base in
    "mkdir -p " ^ p_cfg.fragment_cache_dir |> Shell.cmd;
    [alba_bin; "proxy-start"; "--config"; p_cfg_file]
    |> Shell.detach ~out

  method upload_object namespace file name =
    ["proxy-upload-object";
     "-h";"127.0.0.1";
     namespace; file ; name ]
    |> _alba_cmd_line ~ignore_tls:true

  method download_object namespace name file =
    ["proxy-download-object";
     "-h";"127.0.0.1";
     namespace; name ;file ]
    |> _alba_cmd_line ~ignore_tls:true

  method create_namespace name =
    _alba_cmd_line ~ignore_tls:true ["proxy-create-namespace"; "-h"; "127.0.0.1"; name]
end

type maintenance_cfg = {
    albamgr_cfg_file : string;
    log_level : string;
    tls_client : tls_client option;
  } [@@deriving yojson]

let make_maintenance_config abm_cfg_file tls_client =
  { albamgr_cfg_file = abm_cfg_file;
    log_level = "debug";
    tls_client ;
  }

class maintenance id cfg abm_cfg_file =
  let maintenance_base =
    Printf.sprintf "%s/maintenance/%02i" cfg.alba_base_path id
  in
  let maintenance_abm_cfg_file = maintenance_base ^ "/abm.ini" in
  let tls_client = make_tls_client cfg in
  let m_cfg = make_maintenance_config maintenance_abm_cfg_file tls_client in
  let m_cfg_file = maintenance_base ^ "/maintenance.cfg" in


  object
    method abm_config_file = maintenance_abm_cfg_file

    method write_config_file : unit =
      "mkdir -p " ^ maintenance_base |> Shell.cmd;
      let () = Shell.cp abm_cfg_file maintenance_abm_cfg_file in
      let oc = open_out m_cfg_file in
      let json = maintenance_cfg_to_yojson m_cfg in
      Yojson.Safe.pretty_to_channel oc json;
      close_out oc

    method start =
      let out = Printf.sprintf "%s/maintenance.out" maintenance_base in
      [cfg.alba_bin; "maintenance"; "--config"; m_cfg_file]
      |> Shell.detach ~out

    method signal s=
      let pid_line = ["pgrep -a alba"; "| grep 'maintenance' " ]
                     |> Shell.cmd_with_capture
      in
      let pid = Scanf.sscanf pid_line " %i " (fun i -> i) in
      Printf.sprintf "kill -s %s %i" s pid |> Shell.cmd


end



type tls = { cert:string; key:string; port : int} [@@ deriving yojson]

type asd_cfg = {
    node_id: string;
    home : string;
    log_level : string;
    ips : string list;
    port : int option;
    asd_id : string;
    limit : int;
    __sync_dont_use: bool;
    multicast: float option;
    tls: tls option;
  }[@@deriving yojson]

let make_asd_config node_id asd_id home port tls=
  {node_id;
   asd_id;
   home;
   port;
   ips = [];
   log_level = "debug";
   limit= 99;
   __sync_dont_use = false;
   multicast = Some 10.0;
   tls;
  }



class asd node_id asd_id alba_bin arakoon_path home port tls =
  let use_tls = tls <> None in
  let a_cfg = make_asd_config node_id asd_id home port tls in
  let a_cfg_file = home ^ "/cfg.json" in
  let kill_port = match port with
    | None ->
       begin
         match tls with
         | Some tls -> tls.port
         | None -> failwith "no port?"
       end
    | Some p -> p
  in
  object(self)
    method config_file = a_cfg_file

    method tls = tls

    method write_config_files =
      "mkdir -p " ^ home |> Shell.cmd;
      if use_tls
      then
        begin
        let base = Printf.sprintf "%s/%s" arakoon_path asd_id in
        "mkdir -p " ^ base |> Shell.cmd;
        make_cert base asd_id;
        end;
      let oc = open_out a_cfg_file in
      let json = asd_cfg_to_yojson a_cfg in
      let json' =
        if use_tls
        then json
        else suppress_tags ["multicast"] json
      in
      Yojson.Safe.pretty_to_channel oc json' ;
      close_out oc

    method start =
      let out = home ^ "/stdout" in
      [alba_bin; "asd-start"; "--config"; a_cfg_file]
      |> Shell.detach ~out;

    method stop =
      Printf.sprintf "fuser -k -n tcp %i" kill_port
      |> Shell.cmd

    method private build_remote_cli ?(json=true) what  =
      let p = match tls with
        | Some tls -> tls.port
        | None -> begin match port with | Some p -> p | None -> failwith "bad config" end
      in
      let cmd0 = [ alba_bin;]
                 @ what
                 @ ["-h"; "127.0.0.1";"-p"; string_of_int p;]
      in
      let cmd1 = if use_tls then _alba_extend_tls cmd0 else cmd0 in
      let cmd2 = if json then cmd1 @ ["--to-json"] else cmd1 in
      cmd2
    method get_remote_version =
      let cmd = self # build_remote_cli ["asd-get-version"] ~json:false in
      cmd |> Shell.cmd_with_capture

    method get_statistics =
      let cmd = self # build_remote_cli ["asd-statistics"] in
      cmd |> Shell.cmd_with_capture

    method set k v =
      let cmd = self # build_remote_cli ["asd-set";k;v] ~json:false in
      cmd |> String.concat " " |> Shell.cmd
    method get k =
      let cmd = self # build_remote_cli ["asd-multi-get"; k] ~json:false in
      cmd |> Shell.cmd_with_capture
end





module Deployment = struct
  type t = {
      cfg : Config.t;
      abm : arakoon;
      nsm : arakoon;
      proxy : proxy;
      maintenance : maintenance;
      osds : asd array;
    }

  let nsm_host_register t : unit =
    let cfg_file = t.nsm # config_file in
    let cmd = ["add-nsm-host"; cfg_file ;
               "--config" ; t.abm # config_file ]
    in
    _alba_cmd_line cmd


  let make_osds n local_nodeid_prefix base_path arakoon_path alba_bin (tls:bool) =
    let base_port = 8000 in
    let rec loop asds j =
      if j = n
      then List.rev asds |> Array.of_list
      else
        begin
          let port = base_port + j in
          let node_id = j lsr 2 in
          let node_id_s = Printf.sprintf "%s_%i" local_nodeid_prefix node_id in
          let asd_id = Printf.sprintf "%04i_%02i_%s" port node_id local_nodeid_prefix in
          let home = base_path ^ (Printf.sprintf "/asd/%02i" j) in
          let tls_cfg =
            if tls
            then
              begin
                let port = port + 500 in
                let base = Printf.sprintf "%s/%s" arakoon_path asd_id in
                Some { cert = Printf.sprintf "%s/%s.pem" base asd_id ;
                       key  = Printf.sprintf "%s/%s.key" base asd_id ;
                       port ;
                     }
              end
            else None
          in
          let asd = new asd node_id_s asd_id
                        alba_bin
                        arakoon_path
                        home (Some port) tls_cfg
          in
          loop (asd :: asds) (j+1)
        end
    in
    loop [] 0

  let make_default () =
    let cfg = Config.default in
    let abm =
      let id = "abm"
      and nodes = ["abm_0"; "abm_1"; "abm_2"]
      and base_port = 4000 in
      new arakoon id nodes base_port
    in
    let nsm =
      let id = "nsm"
      and nodes = ["nsm_0";"nsm_1"; "nsm_2"]
      and base_port = 4100 in
      new arakoon id nodes base_port
    in
    let proxy       = new proxy       0 cfg cfg.alba_bin (abm # config_file) in
    let maintenance = new maintenance 0 cfg (abm # config_file) in
    let osds = make_osds cfg.n_osds
                         cfg.local_nodeid_prefix
                         cfg.alba_base_path
                         cfg.arakoon_path
                         cfg.alba_bin
                         cfg.tls
    in
    { cfg; abm;nsm; proxy ; maintenance; osds }

  let to_arakoon_189 t =
    let new_binary = t.cfg.arakoon_189_bin in
    let new_plugin_path = t.cfg.alba_06_plugin_path in
    let t' = { t with
               cfg = { t.cfg with
                       arakoon_bin = new_binary;
                       alba_plugin_path = new_plugin_path;
                     };
             }
    in
    t'.abm # to_arakoon_189;
    t'.nsm # to_arakoon_189;
    t'

  let setup_osds t =
    Array.iter (fun asd ->
                asd # write_config_files;
                asd # start
               ) t.osds

  let claim_osd t long_id =
    let cmd = [
        "claim-osd";
        "--long-id"; long_id;
        "--config" ; t.abm # config_file;
      ]
    in
    _alba_cmd_line cmd


  let claim_osds t long_ids =
    List.fold_left
      (fun acc long_id ->
       try
         let () = claim_osd t long_id in
         long_id :: acc
       with _ -> acc
      )
      [] long_ids


  let parse_harvest osds_json_s =
    let json = Yojson.Safe.from_string osds_json_s in
    (*let () = Printf.printf "available_json:%S" available_json_s in*)
    let basic = Yojson.Safe.to_basic json  in
    match basic with
    | `Assoc [
        ("success", `Bool true);
        ("result", `List result)] ->
       begin
         (List.fold_left
            (fun acc x ->
             match x with
             | `Assoc (_::_
                       :: _ (* ips *)
                       :: _ (*("port",`Int port)*)
                       ::_ :: _
                       :: _ (*("node_id", `String node_id) *)
                       :: ("long_id", `String long_id)
                       :: _
                       :: _) ->
                long_id :: acc
             | _ -> acc
            ) [] result)
       end
    | _ -> failwith "unexpected json format"

  let harvest_available_osds t =
    let available_json_s =
      let cmd =
        [t.cfg.alba_bin;
         "list-available-osds"; "--config"; t.abm # config_file ; "--to-json"
        ]
      in
      let cmd' = if t.cfg.tls then _alba_extend_tls cmd else cmd in
      cmd' |> Shell.cmd_with_capture
    in
    parse_harvest available_json_s

  let claim_local_osds t n =
    let do_round() =
      let long_ids = harvest_available_osds t in
      let locals = List.filter (fun x -> true) long_ids in
      let claimed = claim_osds t locals in
      List.length claimed
    in
    let rec loop j c =
      if j = n || c > 20
      then ()
      else
        let n_claimed = do_round() in
        Unix.sleep 1;
        loop (j+n_claimed) (c+1)
    in
    loop 0 0

  let stop_osds t =
    Array.iter (fun asd -> asd # stop) t.osds


  let restart_osds t =
    stop_osds t ;
    Array.iter
      (fun asd -> asd # start)
      t.osds




  let list_namespaces t  =
    let r = [t.cfg.alba_bin; "list-namespaces";
             "--config"; t.abm # config_file;
             "--to-json";
            ] |> Shell.cmd_with_capture in
    let json = Yojson.Safe.from_string r in
    let basic = Yojson.Safe.to_basic json  in
    match basic with
    | `Assoc [
        ("success", `Bool true);
        ("result", `List result)] ->
       List.map
         (function
             | `Assoc
               [("id", `Int id); ("name", `String name);
                ("nsm_host_id", `String nsm_host); ("state", `String state);
                ("preset_name", `String preset_name)]
               -> (id,name, nsm_host, state, preset_name)
             | _ -> failwith "bad structure"
         )
         result
    | _ -> failwith "?"

  let install_monitoring t =
    let arakoons = ["pgrep";"-a";"arakoon"] |> Shell.cmd_with_capture in
    let albas    = ["pgrep";"-a";"alba"]    |> Shell.cmd_with_capture in
    let oc = open_out t.cfg.monitoring_file in
    output_string oc arakoons;
    output_string oc "\n";
    output_string oc albas;
    output_string oc "\n";
    close_out oc;
    let get_pids text =
      let lines = Str.split (Str.regexp "\n") text in
      List.map (fun line -> Scanf.sscanf line "%i " (fun x -> x)) lines
    in
    let arakoon_pids = get_pids arakoons in
    let alba_pids = get_pids albas in
    let pids = arakoon_pids @ alba_pids in
    let args = List.fold_left (fun acc pid -> "-p"::(string_of_int pid):: acc) ["1"] pids in
    "pidstat" :: args |> Shell.detach ~out:t.cfg.monitoring_file




  let setup t =
    let cfg = t.cfg in
    let _ = _arakoon_cmd_line ["--version"] in
    let _ = _alba_cmd_line ~ignore_tls:true ["version"] in
    if cfg.tls
    then
      begin
        "mkdir -p " ^ cfg.arakoon_path |> Shell.cmd;
        make_ca cfg;
        let my_client = "my_client" in
        let client_path = cfg.arakoon_path ^ "/" ^ my_client in
        "mkdir " ^ client_path |> Shell.cmd;
        make_cert client_path my_client
      end;

    t.abm # write_config_files;
    t.abm # start ;

    t.nsm # write_config_files;
    t.nsm # start ;

    let _ = t.abm # wait_for_master () in
    let _ = t.nsm # wait_for_master () in

    t.proxy # write_config_file;
    t.proxy # start;


    t.maintenance # write_config_file;
    t.maintenance # start;

    nsm_host_register t;

    setup_osds t;

    claim_local_osds t t.cfg.n_osds;

    t.proxy # create_namespace "demo";
    install_monitoring t


  let kill t =
    let cfg = t.cfg in
    let pkill x = (Printf.sprintf "pkill -e -9 %s" x) |> Shell.cmd ~ignore_rc:true in
    pkill (Filename.basename cfg.arakoon_bin);
    pkill (Filename.basename cfg.alba_bin);
    pkill "'java.*SimulatorRunner.*'";
    "fuser -k -f " ^ cfg.monitoring_file |> Shell.cmd ~ignore_rc:true ;
    t.abm # remove_dirs;
    "rm -rf " ^ cfg.alba_base_path |> Shell.cmd;
    "rm -rf " ^ cfg.arakoon_path   |> Shell.cmd;
    ()

  let proxy_pid t =
    let n = ["fuser";"-n";"tcp";"10000"] |> Shell.cmd_with_capture in
    Scanf.sscanf n " %i" (fun i -> i)

  let smoke_test t =
    let _  = proxy_pid () in
    ()

end

module JUnit = struct
  type result =
    | Ok
    | Err of string
    | Fail of string
    [@@deriving show]

  type testcase = {
      classname:string;
      name: string;
      time: float;
      result : result;
    } [@@deriving show]

  let make_testcase classname name time result = {classname;name;time; result}
  type suite = { name:string; time:float; tests : testcase list}[@@deriving show]

  let make_suite name tests time = {name;tests;time}

  let dump_xml suites fn =
    let dump_test oc test =
      let element =
        Printf.sprintf
          "      <testcase classname=%S name=%S time=\"%f\" >\n"
          test.classname test.name test.time
      in
      output_string oc element;
      let () = match test.result with
      | Ok -> ()
      | Err s  -> output_string oc (Printf.sprintf "        <error>%s</error>\n" s)
      | Fail s -> output_string oc (Printf.sprintf "        <failure>%s</failure" s)
      in
      output_string oc "      </testcase>\n"
    in
    let dump_suite oc suite =
      let element =
        let errors,failures,size =
          List.fold_left
            (fun (n_errors,n_failures,n) test ->
             match test.result with
             | Ok     -> (n_errors,     n_failures    , n+1)
             | Err _  -> (n_errors + 1, n_failures    , n+1)
             | Fail _ -> (n_errors,     n_failures +1 , n+1)
            ) (0,0,0) suite.tests
        in
        Printf.sprintf
          ("    <testsuite errors=\"%i\" failures=\"%i\" name=%S skipped=\"0\" "
          ^^ "tests=\"%i\" time=\"%f\" >\n")
          errors failures
          suite.name size
          suite.time
      in
      output_string oc element;
      List.iter (fun test -> dump_test oc test) suite.tests;
      output_string oc "    </testsuite>\n";
    in
    let oc = open_out fn in
    output_string oc "<?xml version=\"1.0\" ?>\n";
    output_string oc "  <testsuites >\n";
    List.iter (fun suite -> dump_suite oc suite) suites;
    output_string oc "  </testsuites>\n";
    close_out oc

  let dump suites =
    Printf.printf "%s\n" ([% show : suite list] suites)
end

module Test = struct
  open Deployment
  let wrapper f t =
    let t = Deployment.make_default () in
    Deployment.kill t;
    Deployment.setup t;
    f t;
    Deployment.smoke_test t

  let no_wrapper f t =
    let _ = f t
    in ()


  let cpp ?(xml=false) ?filter ?dump (t:Deployment.t) =
    let cfg = t.Deployment.cfg in
    let cmd =
      ["cd";cfg.alba_home; "&&"; "LD_LIBRARY_PATH=./cpp/lib"; "./cpp/bin/unit_tests.out";
      ]
    in
    let cmd2 = if xml then cmd @ ["--gtest_output=xml:gtestresults.xml" ] else cmd in
    let cmd3 = match filter with
      | None -> cmd2
      | Some f -> cmd2 @ ["--gtest_filter=" ^ f]
    in
    cmd3 |> String.concat " " |> Shell.cmd

  let stress ?(xml=false) ?filter ?dump (t:Deployment.t) =
    let t0 = Unix.gettimeofday() in
    let n = 3000 in
    let rec loop i =
      if i = n
      then ()
      else
        let name = Printf.sprintf "%08i" i in
        let () = t.Deployment.proxy # create_namespace name in
        loop (i+1)
    in
    let () = loop 0 in
    let namespaces = Deployment.list_namespaces t in
    let t1 = Unix.gettimeofday () in
    let d = t1 -. t0 in
    assert ((n+1) = List.length namespaces);
    if xml
    then
      begin
        let open JUnit in
        let time = d in
        let testcase = make_testcase "package.test" "testname" time JUnit.Ok in
        let suite    = make_suite "stress test suite" [testcase] time in
        let suites   = [suite] in
        dump_xml suites "testresults.xml"
      end
    else ()


  let ocaml ?(xml=false) ?filter ?dump t =
    begin

      let cfg = t.Deployment.cfg in
      if cfg.tls
      then
        begin (* make cert for extra asd (test_discover_claimed) *)
          let asd_id = "test_discover_claimed" in
          let base = Printf.sprintf "%s/%s" cfg.arakoon_path asd_id in
          "mkdir -p " ^ base |> Shell.cmd;
          make_cert base asd_id;
        end;
      let cmd = [
          (*"valgrind"; "--track-origins=yes";*)
          cfg.alba_bin; "unit-tests"; "--config" ; t.abm # config_file ]
      in
      let cmd2 = if xml then cmd @ ["--xml=true"] else cmd in
      let cmd3 = if cfg.tls then _alba_extend_tls cmd2 else cmd2 in
      let cmd4 = match filter with
        | None -> cmd3
        | Some filter -> cmd3 @ ["--only-test=" ^ filter] in
      let cmd5 = match dump with
        | None -> cmd4
        | Some dump -> cmd4 @ [" > " ^ dump] in
      let cmd_s = cmd5 |> String.concat " " in
      let () = Printf.printf "cmd_s = %s\n%!" cmd_s in
      cmd_s
      |> Shell.cmd
    end

  let voldrv_backend ?(xml=false) ?filter ?dump t =
    let cfg = t.Deployment.cfg in
    let cmd = [
        cfg.voldrv_backend_test;
        "--skip-backend-setup"; "1";
        "--backend-config-file"; cfg.alba_home ^ "/cfg/backend.json";
        "--loglevel=error";
      ]
    in
    let cmd2 = if xml then cmd @ ["--gtest_output=xml:gtestresults.xml"] else cmd in
    let cmd3 = match filter with
      | None -> cmd2
      | Some dump -> cmd2 @ []
    in
    let cmd4 = match dump with
      | None -> cmd3
      | Some dump -> cmd3 @ ["> " ^ dump ^ " 2>&1"]
    in

    let cmd_s = cmd4 |> String.concat " " in
    let () = Printf.printf "cmd_s = %s\n%!" cmd_s in
    cmd_s |> Shell.cmd

  let voldrv_tests ?(xml = false) ?filter ?dump t =
    let cfg = t.Deployment.cfg in
    let cmd = [cfg.voldrv_test;
               "--skip-backend-setup";"1";
               "--backend-config-file"; cfg.alba_home ^ "/cfg/backend.json";
               "--loglevel=error"]
    in
    let cmd2 = if xml then cmd @ ["--gtest_output=xml:gtestresults.xml"] else cmd in
    let cmd3 = match filter with
      | None -> cmd2 @ ["--gtest_filter=SimpleVolumeTests/SimpleVolumeTest*"]
      | Some filter -> cmd2 @ ["--gtest_filter=" ^ filter]
    in
    let cmd4 = match dump with
      | None -> cmd3
      | Some dump -> cmd3 @ ["> " ^ dump ^ " 2>&1"]
    in
    let cmd_s = cmd4 |> String.concat " " in
    let () = Printf.printf "cmd_s = %s\n%!" cmd_s in
    cmd_s |> Shell.cmd


  let disk_failures ?(xml= false) ?filter ?dump t =
    let cfg = t.Deployment.cfg in
    let cmd = [
        cfg.failure_tester;
        "--config" ; t.abm # config_file;
      ]
    in
    let cmd2 = if xml then cmd @ ["--xml=true"] else cmd in
    let cmd_s = cmd2 |> String.concat " " in
    let () = Printf.printf "cmd_s = %s\n%!" cmd_s in
    cmd_s |> Shell.cmd

  let asd_start ?(xml=false) ?filter ?dump t =
    let cfg = t.Deployment.cfg in
    let t0 = Unix.gettimeofday() in
    let object_location = cfg.alba_base_path ^ "/obj" in
    let cmd_s = Printf.sprintf "dd if=/dev/urandom of=%s bs=1M count=1" object_location in
    cmd_s |> Shell.cmd;
    let rec loop i =
      if i = 1000
      then ()
      else
        let () = t.proxy # upload_object "demo" object_location (string_of_int i) in
        loop (i+1)
    in
    loop 0;
    Deployment.restart_osds t;
    let attempt ()  =
      try [
        "proxy-upload-object";
        "-h";"127.0.0.1";
        "demo";object_location;
        "some_other_name";"--allow-overwrite";
        ] |> _alba_cmd_line ~ignore_tls:true;
          true
      with
      | _ -> false
    in
    let () =
        attempt () |> ignore;
        attempt () |> ignore;
        attempt () |> ignore;
        Unix.sleep 2;
        attempt () |> ignore;
    in
    let ok = attempt () in
    Printf.printf "ok:%b\n%!" ok;
    Deployment.smoke_test t;
    let t1 = Unix.gettimeofday() in
    let d = t1 -. t0 in
    if xml
    then
      begin
        let open JUnit in
        let time = d in
        let testcase = make_testcase "package.test" "testname" time JUnit.Ok in
        let suite    = make_suite "stress test suite" [testcase] time in
        let suites   = [suite] in
        dump_xml suites "testresults.xml"
      end
    else
      ()

  let asd_get_version t =
    try
      let version_s = t.Deployment.osds.(1) # get_remote_version in
      Printf.printf "version_s=%S\n%!" version_s;
      match
        version_s.[0] = '(' &&
          String.length version_s > 4
      with
      | true -> JUnit.Ok
      | false ->JUnit.Fail "failed test"
    with exn -> JUnit.Err (Printexc.to_string exn)

  let asd_get_statistics t =
    let stats_s = t.Deployment.osds.(1) # get_statistics in
    try
      let _ = Yojson.Safe.from_string stats_s in
      JUnit.Ok
    with x -> JUnit.Err (Printexc.to_string x)

  let asd_crud t  =
    let k = "the_key"
    and v = "the_value" in
    let osd = t.Deployment.osds.(1) in
    osd # set k v;
    let v2 = osd # get k in
    match Str.search_forward (Str.regexp v) v2 0  <> -1 with
    | true      -> JUnit.Ok
    | false     -> JUnit.Fail (Printf.sprintf "%S <---> %S\n" v v2)
    | exception x -> JUnit.Err (Printexc.to_string x)

  let asd_cli_env t =
    if t.Deployment.cfg.tls
    then
      try
        let cert,pem,key = _get_client_tls () in
        let cmd = [Printf.sprintf "ALBA_CLI_TLS='%s,%s,%s'" cert pem key;
                   t.cfg.alba_bin;
                   "asd-get-version";
                   "-h 127.0.0.1";
                   "-p" ; "8501"
                  ]
        in
        let _r = Shell.cmd_with_capture cmd in
        JUnit.Ok
      with exn ->
        JUnit.Err (Printexc.to_string exn)
    else
      JUnit.Ok


  let create_example_preset t =
    let cmd = [
        "create-preset"; "example";
        "--config"; t.Deployment.abm # config_file;
        "< "; "./cfg/preset.json";
      ]
    in
    try
      _alba_cmd_line ~cwd:t.cfg.alba_home cmd;
      JUnit.Ok
    with | x -> JUnit.Err (Printexc.to_string x)

  let cli t =
    let suite_name = "run_tests_cli" in
    let tests = ["asd_crud", asd_crud;
                 "asd_get_version", asd_get_version;
                 "asd_get_statistics", asd_get_statistics;
                 "asd_cli_env", asd_cli_env;
                 "create_example_preset", create_example_preset;
                ]
    in
    let t0 = Unix.gettimeofday() in
    let results =
      List.fold_left (
          fun acc (name,test) ->

          let t0 = Unix.gettimeofday () in
          let result = test t in
          let t1 = Unix.gettimeofday () in
          let d = t1 -. t0 in
          let testcase = JUnit.make_testcase name name d result in
          testcase ::acc
        ) [] tests
    in
    let t1 = Unix.gettimeofday() in
    let d = t1 -. t0 in
    let suite = JUnit.make_suite suite_name results d in
    suite

  let big_object t =
    let inner () =
      let preset = "preset_no_compression" in
      let namespace ="big" in
      let name = "big_object" in
      _alba_cmd_line ~cwd:t.Deployment.cfg.alba_home [
                       "create-preset"; preset;
                       "--config"; t.abm # config_file;
                       " < "; "./cfg/preset_no_compression.json";
                     ];
      _alba_cmd_line [
          "create-namespace";namespace ;preset;
          "--config"; t.abm # config_file;
        ];
      let cfg = t.cfg in
      let object_file = cfg.alba_base_path ^ "/obj" in
      "truncate -s 2G " ^ object_file |> Shell.cmd;
      t.proxy # upload_object   namespace object_file name;
      t.proxy # download_object namespace name (cfg.alba_base_path ^ "obj_download");
    in
    let test_name = "big_object" in
    let t0 = Unix.gettimeofday () in
    let result =
      try inner () ; JUnit.Ok
      with x -> JUnit.Err (Printexc.to_string x)
    in
    let t1 = Unix.gettimeofday () in
    let d = t1 -. t0 in
    let testcase = JUnit.make_testcase test_name test_name d result in
    let suite = JUnit.make_suite "big_object" [testcase] d in
    suite

  let arakoon_changes t =
    let inner () =
      let wait_for x =
        let rec loop j =
          if j = 0
          then ()
          else
            let () = Printf.printf "%i\n%!" j in
            let () = Unix.sleep 1 in
            loop (j-1)
        in
        loop x
      in
      Deployment.kill t;
      let two_nodes = new arakoon "abm" ["abm_0";"abm_1"] 4000 in
      let t' = {t with abm = two_nodes } in

      let upload_albamgr_cfg cfg =
        _alba_cmd_line ["update-abm-client-config";"--attempts";"5";
                        "--config"; cfg]
      in
      let n_nodes_in_config () =
        let r = [t'.cfg.alba_bin; "proxy-client-cfg | grep port | wc" ] |> Shell.cmd_with_capture in
        let c = Scanf.sscanf r " %i " (fun i -> i) in
        c
      in
      Deployment.setup t';
      wait_for 10;
      two_nodes # stop;

      print_endline "grow the cluster";
      let three_nodes = new arakoon "abm" ["abm_0";"abm_1";"abm_2"] 4000 in
      three_nodes # write_cluster_config_file ;
      three_nodes # write_node_config_files "abm_2";
      three_nodes # start_node "abm_1";
      three_nodes # start_node "abm_2";
      wait_for 20;
      three_nodes # start_node "abm_0";

      let maintenance_cfg = t'.maintenance # abm_config_file in

      (* update maintenance *)
      Shell.cp (three_nodes # config_file) maintenance_cfg;

      t'.maintenance # signal "USR1";
      wait_for(120);
      let c = n_nodes_in_config () in
      assert (c = 3);

      print_endline "shrink the cluster";
      three_nodes # stop;
      two_nodes # write_cluster_config_file;
      two_nodes # start;
      Shell.cp (t'.abm # config_file) maintenance_cfg;

      upload_albamgr_cfg (two_nodes # config_file);
      wait_for(120);
      let c = n_nodes_in_config () in
      assert (c = 2);
      ()

    in
    let test_name = "arakoon_changes" in
    let t0 = Unix.gettimeofday () in
    let result =
      try inner () ; JUnit.Ok
      with x -> JUnit.Err (Printexc.to_string x)
    in
    let t1 = Unix.gettimeofday () in
    let d = t1 -. t0 in
    let testcase = JUnit.make_testcase test_name test_name d result in
    let suite = JUnit.make_suite "arakoon_changes" [testcase] d in
    suite

  let compat ?(xml=false) ?filter ?dump t =
    let test old_proxy old_plugins old_asd t =
      let cfg = t.cfg in
      try
        Deployment.smoke_test t;
        let make_cli ?(old=false) extra =
          let bin = if old then failwith "old bin?" else cfg.alba_bin in
          bin :: extra
        in
        let obj_name = "alba_binary"
        and ns = "demo"
        and host = "127.0.0.1"
        in
        let basic_tests =
          [
            ["proxy-upload-object"; "-h"; host; ns; cfg.alba_bin; obj_name];
            ["proxy-download-object"; "-h"; host; ns; obj_name; "/tmp/downloaded.bin"];
            ["delete-object"; ns; obj_name; "--config"; t.abm # config_file];
          ]
        in
        List.iter
          (fun t -> t |> make_cli |> String.concat " " |> Shell.cmd )
          basic_tests;

        (* explicit backward compatible operations *)
        let r = make_cli ["list-all-osds"; "--config"; t.abm # config_file; "--to-json"]
              |> Shell.cmd_with_capture
        in
        let osds = Deployment.parse_harvest r in
        let long_id = List.hd osds in

        (* decommission 1 asd *)
        make_cli ["decommission-osd";"--long-id"; long_id;
                  "--config"; t.abm # config_file ]
        |> String.concat " "
        |> Shell.cmd;
        (* list them *)
        let decommissioning_s=
          make_cli ["list-decommissioning-osds";
                    "--config"; t.abm # config_file; "--to-json"]
          |> Shell.cmd_with_capture
        in
        let decommissioning = decommissioning_s |> Deployment.parse_harvest in
        assert (List.length decommissioning = 1 )
    with exn ->
      Shell.cmd "pgrep -a alba";
      Shell.cmd "pgrep -a arakoon";
      raise exn
    in
    let deploy_and_test old_proxy old_plugins old_asds =
      let t =
        let maybe_old_asds tx =
          if old_asds
          then
            {tx with osds = make_osds tx.cfg.n_osds
                                      tx.cfg.local_nodeid_prefix
                                      tx.cfg.alba_base_path
                                      tx.cfg.arakoon_path
                                      tx.cfg.alba_06_bin
                                      false
            }
          else tx
        in
        let maybe_old_plugins tx =
          if old_plugins
          then
            Deployment.to_arakoon_189 tx
          else tx
        in
        let maybe_old_proxy tx =
          if old_proxy
          then
            let old_proxy =
              new proxy 0 tx.cfg
                  tx.cfg.alba_06_bin
                  (tx.abm # config_file)
            in
            {tx with proxy = old_proxy }
          else tx
        in
        Deployment.make_default ()
        |> maybe_old_asds
        |> maybe_old_plugins
        |> maybe_old_proxy
      in
      Deployment.kill t; (* too precise, previous deployment is slightly different  *)
      Shell.cmd "pkill alba" ~ignore_rc:true;
      Shell.cmd "pkill arakoon" ~ignore_rc:true;

      t.abm # write_config_files;
      t.abm # start;

      t.nsm # write_config_files;
      t.nsm # start;

      let _ = t.abm # wait_for_master () in
      let _ = t.nsm # wait_for_master () in

      if old_plugins
      then
        begin
          let signature = "3cd787f7a0bcb6c8dbf40a8b4a3a5f350fa87d1bff5b33f5d099ab850e44aaeca6e3206b595d7cb361eed28c5dd3c0f3b95531d931a31a058f3c054b04917797b7363457f7a156b5f36c9bf3e1a43b46e5c1e9ca3025c695ef366be6c36a1fc28f5648256a82ca392833a3050e1808e21ef3838d0c027cf6edaafedc8cfe2f2fc37bd95102b92e7de28042acc65b8b6af4cfb3a11dadce215986da3743f1be275200860d24446865c50cdae2ebe2d77c86f6d8b3907b20725cdb7489e0a1ba7e306c90ff0189c5299194598c44a537b0a460c2bf2569ab9bb99c72f6415a2f98c614d196d0538c8c19ef956d42094658dba8d59cfc4a024c18c1c677eb59299425ac2c225a559756dee125ef93c38c211cda69c892d26ca33b7bd2ca95f15bbc1bb755c46574432005b8afcab48a0a5ed489854cec24207cddc7ab632d8715c1fb4b1309b45376a49e4c2b4819f27d9d6c8170c59422a0b778b9c3ac18e677bc6fa6e2a2527365aca5d16d4bc6e22007debef1989d08adc9523be0a5d50309ef9393eace644260345bb3d442004c70097fffd29fe315127f6d19edd4f0f46ae2f10df4f162318c4174b1339286f8c07d5febdf24dc049a875347f6b2860ba3a71b82aba829f890192511d6eddaacb0c8be890799fb5cb353bce7366e8047c9a66b8ee07bf78af40b09b4b278d8af2a9333959213df6101c85dda61f2944237c8" in
          [t.cfg.alba_06_bin;
           "apply-license";
           t.cfg.license_file;
           signature;
           "--config"; t.abm # config_file
          ] |> String.concat " " |> Shell.cmd
        end;
      t.proxy # write_config_file;
      t.proxy # start;

      t.maintenance # write_config_file;
      t.maintenance # start;

      Deployment.nsm_host_register t;
      Deployment.setup_osds t;
      Deployment.claim_local_osds t t.cfg.n_osds;
      t.proxy # create_namespace "demo";

      test old_proxy old_plugins old_asds t
    in
    let rec loop acc flavour =
      if flavour = 8
      then acc
      else
        let old_proxy   = flavour land 4 = 4
        and old_plugins = flavour land 2 = 2
        and old_asds    = flavour land 1 = 1
        and test_name   = Printf.sprintf "flavour_%i" flavour
        in
        let t0 = Unix.gettimeofday() in
        let result =
          try
            deploy_and_test old_proxy old_plugins old_asds;
            JUnit.Ok;
          with exn ->
            JUnit.Err (Printexc.to_string exn)
        in
        let t1 = Unix.gettimeofday() in
        let d = t1 -. t0 in
        let testcase = JUnit.make_testcase "TestCompat" test_name d result in
        loop (testcase :: acc) (flavour +1)
    in
    let t0 = Unix.gettimeofday () in
    let testcases = loop [] 0 in
    let t1 = Unix.gettimeofday () in
    let d = t1 -. t0 in
    let suite = JUnit.make_suite "compatibility" testcases d in
    let results = [suite] in
    if xml
    then JUnit.dump_xml results "./testresults.xml"
    else JUnit.dump results



  let everything_else ?(xml=false) ?filter ?dump t =
    let suites =
      [ big_object;
        cli;
        arakoon_changes;
      ]
    in
    let results = List.map (fun s -> s t) suites in
    if xml
    then
       JUnit.dump_xml results "./testresults.xml"
    else
      JUnit.dump results


end


let () =
  let cmd_len = Array.length Sys.argv in
  Printf.printf "cmd_len:%i\n%!" cmd_len;
  if cmd_len = 2
  then
    let test, setup = match Sys.argv.(1) with
      | "ocaml"           -> Test.ocaml, true
      | "cpp"             -> Test.cpp, true
      | "voldrv_backend"  -> Test.voldrv_backend, true
      | "voldrv_tests"    -> Test.voldrv_tests, true
      | "disk_failures"   -> Test.disk_failures, true
      | "stress"          -> Test.stress,true
      | "asd_start"       -> Test.asd_start,true
      | "everything_else" -> Test.everything_else, true
      | "compat"          -> Test.compat, false
      | _  -> failwith "no test"
    in
    let t = Deployment.make_default () in
    let w =
      if setup
      then Test.wrapper
      else Test.no_wrapper
    in
    w (test ~xml:true) t
