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

(* TODO:
   - remove std::exception from llio.cc?
 *)

open! Prelude
open Stat
open Range_query_args2
open Checksum

module ProxySession = struct
  type t = { mutable manifest_ser : int}
  let make () = { manifest_ser = 1}
  let set_manifest_ser t v = t.manifest_ser <- v
end


module ProxyStatistics = struct
    include Stat


    module H = struct
        type ('a,'b) t = ('a *'b) list [@@deriving show, yojson]

        let h_to a_to b_to =
          Llio2.WriteBuffer.list_to
            (Llio2.WriteBuffer.pair_to
               a_to b_to)

        let h_from a_from b_from =
          Llio2.ReadBuffer.list_from
            (Llio2.ReadBuffer.pair_from
               a_from b_from)

        let find t a = List.assoc a t

        let add t a b = (a,b) :: t

        let remove t a = List.remove_assoc a t

      end

    type ns_t = {
        mutable upload: stat;
        mutable download: stat;
        mutable delete : stat;
        mutable manifest_cached: int;
        mutable manifest_from_nsm  : int;
        mutable manifest_stale : int;
        mutable fragment_cache_hits: int;
        mutable fragment_cache_misses:int;

        mutable partial_read_size: stat;
        mutable partial_read_count: stat;
        mutable partial_read_time : stat;
        mutable partial_read_objects: stat;
      }[@@ deriving show, yojson]

    let ns_make () =
      { upload = Stat.make();
        download = Stat.make();
        delete = Stat.make();
        manifest_cached = 0;
        manifest_from_nsm  = 0;
        manifest_stale = 0;
        fragment_cache_hits = 0;
        fragment_cache_misses = 0;

        partial_read_size    = Stat.make ();
        partial_read_count   = Stat.make ();
        partial_read_time    = Stat.make ();
        partial_read_objects = Stat.make ();
      }

    let ns_to buf t =
      let module Llio = Llio2.WriteBuffer in
      Stat_deser.to_buffer' buf t.upload;
      Stat_deser.to_buffer' buf t.download;
      Llio.int_to buf t.manifest_cached;
      Llio.int_to buf t.manifest_from_nsm;
      Llio.int_to buf t.manifest_stale;
      Llio.int_to buf t.fragment_cache_hits;
      Llio.int_to buf t.fragment_cache_misses;

      Stat_deser.to_buffer' buf t.partial_read_size;
      Stat_deser.to_buffer' buf t.partial_read_count;
      Stat_deser.to_buffer' buf t.partial_read_time;
      Stat_deser.to_buffer' buf t.partial_read_objects;

      Stat_deser.to_buffer' buf t.delete


    let ns_from buf =
      let module Llio = Llio2.ReadBuffer in
      let upload   = Stat_deser.from_buffer' buf in
      let download = Stat_deser.from_buffer' buf in
      let manifest_cached    = Llio.int_from buf in
      let manifest_from_nsm  = Llio.int_from buf in
      let manifest_stale     = Llio.int_from buf in
      let fragment_cache_hits    = Llio.int_from buf in
      let fragment_cache_misses  = Llio.int_from buf in
      (* trick to be able to work with <= 0.6.20 proxies *)
      let (partial_read_size,
           partial_read_count,
           partial_read_time,
           partial_read_objects)
        =
        begin
          if Llio.buffer_done buf
          then
            let r = Stat.make () in
            r,r,r,r
          else
            let s = Stat_deser.from_buffer' buf in
            let c = Stat_deser.from_buffer' buf in
            let t = Stat_deser.from_buffer' buf in
            if Llio.buffer_done buf
            then s,c,t,Stat.make()
            else
              let n = Stat_deser.from_buffer' buf in
              s,c,t,n
        end
      in
      let delete =
        if Llio.buffer_done buf
        then Stat.make ()
        else Stat_deser.from_buffer' buf
      in

      { upload ; download; delete;
        manifest_cached;
        manifest_from_nsm;
        manifest_stale;
        fragment_cache_hits;
        fragment_cache_misses;
        partial_read_size;
        partial_read_count;
        partial_read_time;
        partial_read_objects;
      }

    type t = {
        mutable creation:timestamp;
        mutable period: float;
        mutable ns_stats : (string, ns_t) H.t;
      } [@@deriving show, yojson]

    type t' = {
        t : t;
        changed_ns_stats : (string, unit) Hashtbl.t;
      }

    let make () =
      let creation = Unix.gettimeofday () in
      { t = { creation; period = 0.0;
              ns_stats = [];
            };
        changed_ns_stats = Hashtbl.create 3;
      }

    let to_buffer buf t =
      let module Llio = Llio2.WriteBuffer in
      let ser_version = 1 in Llio.int8_to buf ser_version;
      Llio.float_to buf t.creation;
      Llio.float_to buf t.period;
      H.h_to Llio.string_to ns_to buf t.ns_stats

    let from_buffer buf =
      let module Llio = Llio2.ReadBuffer in
      let ser_version = Llio.int8_from buf in
      assert (ser_version = 1);
      let creation = Llio.float_from buf in
      let period   = Llio.float_from buf in
      let ns_stats = H.h_from Llio.string_from ns_from buf in
      {creation;period;ns_stats}


    let deser = from_buffer, to_buffer

    let stop t = t.period <- Unix.gettimeofday() -. t.creation

    let clone t = { t.t with creation = t.t.creation }

    let clear t =
      Hashtbl.clear t.changed_ns_stats;
      t.t.creation <- Unix.gettimeofday ();
      t.t.period <- 0.0;
      t.t.ns_stats <- []

    let find t ns =
      Hashtbl.replace t.changed_ns_stats ns ();
      try H.find t.t.ns_stats ns
      with Not_found ->
        let v = ns_make () in
        let () = t.t.ns_stats <- H.add t.t.ns_stats ns v in
        v

    let forget t nss =
      let r =
        List.fold_left
          (fun acc ns ->H.remove acc ns)
          t.t.ns_stats nss
      in
      t.t.ns_stats <- r

    let show' ~only_changed t =
      show
        (if only_changed
         then
           { t.t with
             ns_stats =
               List.filter
                 (fun (namespace, _) -> Hashtbl.mem t.changed_ns_stats namespace)
                 t.t.ns_stats
           }
         else t.t)

    let clear_ns_stats_changed t =
      let r = Hashtbl.length t.changed_ns_stats in
      Hashtbl.clear t.changed_ns_stats;
      r

   let new_upload t ns delta =
     let ns_stats = find t ns in
     ns_stats.upload <- _update ns_stats.upload delta

   let new_delete t ns delta =
     let ns_stats = find t ns in
     ns_stats.delete <- _update ns_stats.delete delta

   let incr_manifest_src ns_stats =
     let open Cache in
     function
     | Fast ->
          ns_stats.manifest_cached <- ns_stats.manifest_cached + 1
     | Slow ->
        ns_stats.manifest_from_nsm <- ns_stats.manifest_from_nsm + 1
     | Stale ->
        ns_stats.manifest_stale <- ns_stats.manifest_stale + 1

   let new_download t ns delta manifest_src (fg_hits, fg_misses) =
     let ns_stats = find t ns in
     let () =

       incr_manifest_src ns_stats manifest_src
     in
     let () = ns_stats.fragment_cache_hits <-
                ns_stats.fragment_cache_hits  + fg_hits
     in
     let () = ns_stats.fragment_cache_misses <-
                ns_stats.fragment_cache_misses + fg_misses
     in
     ns_stats.download <- _update ns_stats.download delta

   let new_read_objects_slices
         t ns
         ~total_length ~n_slices ~n_objects ~mf_sources
         ~fc_hits ~fc_misses
         ~took
     =
     let ns_stats = find t ns in
     ns_stats.partial_read_size    <- _update ns_stats.partial_read_size  (float total_length);
     ns_stats.partial_read_count   <- _update ns_stats.partial_read_count (float n_slices);
     ns_stats.partial_read_objects <- _update ns_stats.partial_read_objects (float n_objects);
     ns_stats.partial_read_time    <- _update ns_stats.partial_read_time  took;
     List.iter (incr_manifest_src ns_stats) mf_sources;
     ns_stats.fragment_cache_hits   <- ns_stats.fragment_cache_hits + fc_hits;
     ns_stats.fragment_cache_misses <- ns_stats.fragment_cache_misses + fc_misses;
     ()

   type request = { clear: bool ;
                    forget : string list }

   let request_to buf r =
     let module W = Llio2.WriteBuffer in
     W.bool_to buf r.clear;
     W.list_to W.string_to buf r.forget

   let request_from buf =
     let module R = Llio2.ReadBuffer in
     let clear = R.bool_from buf in
     let forget =
       R.maybe_from_buffer (R.list_from R.string_from) [] buf
     in
     { clear; forget }

   let deser_request = request_from, request_to
end

module Protocol = struct

  let magic = 1148837403l
  let version = 1l

  module Amgrp = Albamgr_protocol.Protocol
  module Nsmhp = Nsm_host_protocol.Protocol
  module Nsmp = Nsm_protocol.Protocol

  module Namespace = Amgrp.Namespace

  type object_name = string[@@deriving show]
  type object_id = string [@@deriving show]

  type file_name = string [@@deriving show]

  type encryption_key = string option
  type overwrite = bool
  type may_not_exist = bool

  type preset_name = string
  type offset = Int64.t [@@deriving show]
  type length = int [@@deriving show]
  type data = string

  type consistent_read = bool [@@deriving show]
  type should_cache = bool [@@deriving show]

  type alba_id = string [@@deriving show]

  type write_barrier = bool [@@deriving show]

  type manifest_with_id = Nsm_model.Manifest.t * int64 [@@deriving show]

  module Assert =
    struct

      type t = Nsm_model.Assert.t =
             | ObjectExists of object_name
             | ObjectDoesNotExist of object_name
             | ObjectHasId of object_name * object_id
             | ObjectHasChecksum of object_name * Checksum.t
      [@@deriving show]

      let to_buffer buf =
        let module L = Llio2.WriteBuffer in
        function
        | ObjectExists object_name ->
           L.int8_to buf 1;
           L.string_to buf object_name
        | ObjectDoesNotExist object_name ->
           L.int8_to buf 2;
           L.string_to buf object_name
        | ObjectHasId (object_name, object_id) ->
           L.int8_to buf 3;
           L.string_to buf object_name;
           L.string_to buf object_id
        | ObjectHasChecksum (object_name, cs) ->
           L.int8_to buf 4;
           L.string_to buf object_name;
           Checksum_deser.to_buffer' buf cs

      let from_buffer buf =
        let module L = Llio2.ReadBuffer in
        match L.int8_from buf with
        | 1 ->
           let object_name = L.string_from buf in
           ObjectExists object_name
        | 2 ->
           let object_name = L.string_from buf in
           ObjectDoesNotExist object_name
        | 3 ->
           let object_name = L.string_from buf in
           let object_id = L.string_from buf in
           ObjectHasId (object_name, object_id)
        | 4 ->
           let object_name = L.string_from buf in
           let cs = Checksum_deser.from_buffer' buf in
           ObjectHasChecksum (object_name, cs)
        | k ->
           raise_bad_tag "Proxy_protocol.Assert" k

      let deser = from_buffer, to_buffer
    end
  module Update =
    struct
      type t =
        | UploadObjectFromFile of (object_name * file_name * Checksum.t option)
        | UploadObject of (object_name * Bigstring_slice.t * Checksum.t option)
        | DeleteObject of object_name
      [@@deriving show]

      let to_buffer buf =
        let module L = Llio2.WriteBuffer in
        function
        | UploadObjectFromFile (object_name, file_name, cs_o) ->
           L.int8_to buf 1;
           L.string_to buf object_name;
           L.string_to buf file_name;
           L.option_to Checksum_deser.to_buffer' buf cs_o
        | UploadObject (object_name, blob, cs_o) ->
           L.int8_to buf 2;
           L.string_to buf object_name;
           L.bigstring_slice_to buf blob;
           L.option_to Checksum_deser.to_buffer' buf cs_o
        | DeleteObject object_name ->
           L.int8_to buf 3;
           L.string_to buf object_name

      let from_buffer buf =
        let module L = Llio2.ReadBuffer in
        match L.int8_from buf with
        | 1 ->
           let object_name = L.string_from buf in
           let file_name = L.string_from buf in
           let cs_o = L.option_from Checksum_deser.from_buffer' buf in
           UploadObjectFromFile (object_name, file_name, cs_o)
        | 2 ->
           let object_name = L.string_from buf in
           let blob = L.bigstring_slice_from buf in
           let cs_o = L.option_from Checksum_deser.from_buffer' buf in
           UploadObject (object_name, blob, cs_o)
        | 3 ->
           let object_name = L.string_from buf in
           DeleteObject object_name
        | k ->
           raise_bad_tag "Proxy_protocol.Update" k

      let deser = from_buffer, to_buffer
    end

  type ('i, 'o) request =
    | ListNamespaces : (string RangeQueryArgs.t,
                        Namespace.name counted_list * has_more) request
    | ListNamespaces2 : (string RangeQueryArgs.t,
                         (Namespace.name * preset_name) counted_list * has_more) request
    | NamespaceExists : (Namespace.name, bool) request
    | CreateNamespace : (Namespace.name * preset_name option, unit) request
    | DeleteNamespace : (Namespace.name, unit) request

    | ListObjects : (Namespace.name *
                     string RangeQueryArgs.t,
                     object_name counted_list * has_more) request
    | ReadObjectFs : (Namespace.name *
                      object_name *
                      file_name *
                      consistent_read *
                      should_cache,
                      unit) request
    | WriteObjectFs : (Namespace.name *
                       object_name *
                       file_name *
                       overwrite *
                       Checksum.t option,
                       unit) request
    | WriteObjectFs2 : (Namespace.name
                        * object_name
                        * file_name
                        * overwrite
                        * Checksum.t option,
                        manifest_with_id) request
    | DeleteObject : (Namespace.name *
                      object_name *
                      may_not_exist,
                      unit) request
    | GetObjectInfo : (Namespace.name *
                       object_name *
                       consistent_read *
                       should_cache,
                       Int64.t * Nsm_model.Checksum.t) request
    | ReadObjectsSlices : (Namespace.name *
                             (object_name * (offset * length) list) list *
                           consistent_read,
                           data) request
    | ReadObjectsSlices2 : (Namespace.name *
                             (object_name * (offset * length) list) list *
                           consistent_read,
                            (data
                             * ((object_name
                                 * alba_id
                                 * manifest_with_id) list))) request
    | InvalidateCache : (Namespace.name, unit) request
    | DropCache : (Namespace.name, unit) request
    | ProxyStatistics : (ProxyStatistics.request, ProxyStatistics.t) request
    | GetVersion : (unit, (int * int * int * string)) request
    | OsdView : (unit, (string * Albamgr_protocol.Protocol.Osd.ClaimInfo.t) counted_list
                       * (Albamgr_protocol.Protocol.Osd.id
                          * Nsm_model.OsdInfo.t
                          * Osd_state.t) counted_list) request
    | GetClientConfig : (unit, Alba_arakoon.Config.t) request
    | Ping : (float, float) request
    | OsdInfo : (unit,
                 (Albamgr_protocol.Protocol.Osd.id *
                    Nsm_model.OsdInfo.t *
                      Capabilities.OsdCapabilities.t) counted_list )
                  request
    | OsdInfo2 : (unit,
                  ((alba_id * (Albamgr_protocol.Protocol.Osd.id * Nsm_model.OsdInfo.t *
                               Capabilities.OsdCapabilities.t) counted_list) counted_list)
                 ) request
    | ApplySequence : (Namespace.name *
                         write_barrier * Assert.t list * Update.t list,
                       (object_name * alba_id * manifest_with_id) list) request
    | ReadObjects : (Namespace.name
                     * object_name list
                     * consistent_read
                     * should_cache,
                     Namespace.id * (Nsm_model.Manifest.t * Bigstring_slice.t)
                                      option list)
                      request
    | MultiExists : (Namespace.name * object_name list, bool list) request
    | GetAlbaId : (unit, alba_id) request
    | HasLocalFragmentCache : (unit, bool) request
    | UpdateSession : ((string * string option) list ,
                       (string * string) list) request
    | GetFragmentEncryptionKey : (string * Namespace.id, string option) request

  type request' = Wrap : _ request -> request'
  let command_map = [ 1, Wrap ListNamespaces, "ListNamespaces";
                      2, Wrap NamespaceExists, "NamespaceExists";
                      3, Wrap CreateNamespace, "CreateNamespace";
                      4, Wrap DeleteNamespace, "DeleteNamespace";

                      5, Wrap ListObjects, "ListObjects";
                      8, Wrap DeleteObject, "DeleteObject";
                      9, Wrap GetObjectInfo, "GetObjectInfo";
                      10, Wrap ReadObjectFs, "ReadObjectFs";
                      11, Wrap WriteObjectFs, "WriteObjectFs";
                      13, Wrap ReadObjectsSlices, "ReadObjectsSlices";
                      14, Wrap InvalidateCache, "InvalidateCache";
                      15, Wrap ProxyStatistics, "ProxyStatistics";
                      16, Wrap DropCache, "DropCache";
                      17, Wrap GetVersion, "GetVersion";
                      18, Wrap OsdView,    "OsdView";
                      19, Wrap GetClientConfig, "GetClientConfig";
                      20, Wrap Ping, "Ping";
                      21, Wrap WriteObjectFs2, "WriteObjectFs2";
                      22, Wrap OsdInfo, "OsdInfo";
                      23, Wrap ReadObjectsSlices2, "ReadObjectsSlices2";
                      24, Wrap ApplySequence, "ApplySequence";
                      25, Wrap ReadObjects, "ReadObjects";
                      26, Wrap MultiExists, "MultiExists";
                      28, Wrap OsdInfo2, "OsdInfo2";
                      29, Wrap GetAlbaId, "GetAlbaId";
                      30, Wrap ListNamespaces2, "ListNamespaces2";
                      31, Wrap HasLocalFragmentCache, "HasLocalFragmentCache";
                      32, Wrap UpdateSession, "UpdateSession";
                      33, Wrap GetFragmentEncryptionKey, "GetFragmentEncryptionKey";
                    ]

  module Error = struct
    type t =
      | Unknown                 [@value 1]
      | OverwriteNotAllowed     [@value 2]
      | ObjectDoesNotExist      [@value 3]
      | NamespaceAlreadyExists  [@value 4]
      | NamespaceDoesNotExist   [@value 5]
      (* | EncryptionKeyRequired   [@value 6] *)
      | ChecksumMismatch        [@value 7]
      | ChecksumAlgoNotAllowed  [@value 8]
      | PresetDoesNotExist      [@value 9]
      | BadSliceLength          [@value 10]
      | OverlappingSlices       [@value 11]
      | SliceOutsideObject      [@value 12]
      | UnknownOperation        [@value 13]
      | FileNotFound            [@value 14]
      | NoSatisfiablePolicy     [@value 15]
      | ProtocolVersionMismatch [@value 17]
      | AssertFailed            [@value 18]
    [@@deriving show, enum]

    exception Exn of t * string option

    let failwith ?payload err = raise (Exn (err, payload))
    let lwt_failwith ?payload err = Lwt.fail (Exn (err, payload))

    let err2int = to_enum
    let int2err x = Option.get_some_default Unknown (of_enum x)
  end

  let wrap_unknown_operation f =
    try f ()
    with Not_found -> Error.(failwith UnknownOperation)

  let command_to_code =
    let hasht = Hashtbl.create 3 in
    List.iter (fun (code, comm, txt) -> Hashtbl.add hasht comm code) command_map;
    (fun comm -> wrap_unknown_operation (fun () -> Hashtbl.find hasht comm))

  let code_to_command =
    let hasht = Hashtbl.create 3 in
    List.iter (fun (code, comm, txt) -> Hashtbl.add hasht code comm) command_map;
    (fun code -> wrap_unknown_operation (fun () -> Hashtbl.find hasht code))

  let code_to_txt =
    let hasht = Hashtbl.create 3 in
    List.iter (fun (code, _, txt) -> Hashtbl.add hasht code txt) command_map;
    (fun code ->
     try Hashtbl.find hasht code with
     | Not_found -> Printf.sprintf "unknown operation %i" code)

  open Llio2
  let deser_request_i : type i o. (i, o) request -> i Deser.t = function
    | ListNamespaces -> RangeQueryArgs.deser' `MaxThenReverse Deser.string
    | ListNamespaces2 -> RangeQueryArgs.deser' `MaxThenReverse Deser.string
    | NamespaceExists -> Deser.string
    | CreateNamespace -> Deser.tuple2 Deser.string (Deser.option Deser.string)
    | DeleteNamespace -> Deser.string

    | ListObjects ->
      Deser.tuple2
        Deser.string
        (RangeQueryArgs.deser' `MaxThenReverse Deser.string)
    | ReadObjectFs ->
      Deser.tuple5
        Deser.string
        Deser.string
        Deser.string
        Deser.bool
        Deser.bool
    | WriteObjectFs ->
      Deser.tuple5
        Deser.string
        Deser.string
        Deser.string
        Deser.bool
        (Deser.option Checksum_deser.deser')
    | WriteObjectFs2 ->
       Deser.tuple5
         Deser.string
         Deser.string
         Deser.string
         Deser.bool
         (Deser.option Checksum_deser.deser')
    | DeleteObject ->
      Deser.tuple3
        Deser.string
        Deser.string
        Deser.bool
    | GetObjectInfo ->
      Deser.tuple4
        Deser.string
        Deser.string
        Deser.bool
        Deser.bool
    | ReadObjectsSlices ->
      Deser.tuple3
        Deser.string
        (Deser.list
           (Deser.pair
              Deser.string
              (Deser.list
                 (Deser.tuple2
                    Deser.int64
                    Deser.int))))
        Deser.bool
    | ReadObjectsSlices2 ->
       Deser.tuple3
        Deser.string
        (Deser.list
           (Deser.pair
              Deser.string
              (Deser.list
                 (Deser.tuple2
                    Deser.int64
                    Deser.int))))
        Deser.bool
    | InvalidateCache -> Deser.string
    | DropCache -> Deser.string
    | ProxyStatistics -> ProxyStatistics.deser_request
    | GetVersion      -> Deser.unit
    | OsdView         -> Deser.unit
    | GetClientConfig -> Deser.unit
    | Ping            -> Deser.float
    | OsdInfo         -> Deser.unit
    | OsdInfo2        -> Deser.unit
    | ApplySequence ->
       Deser.tuple4
         Deser.string
         Deser.bool
         (Deser.list Assert.deser)
         (Deser.list Update.deser)
    | ReadObjects ->
       Deser.tuple4
         Deser.string
         (Deser.list Deser.string)
         Deser.bool
         Deser.bool
    | MultiExists ->
       Deser.pair
         Deser.string
         (Deser.list Deser.string)
    | GetAlbaId ->
       Deser.unit
    | HasLocalFragmentCache ->
       Deser.unit
    | UpdateSession -> Deser.list
                         (Deser.pair
                            Deser.string
                            (Deser.option Deser.string)
                         )
    | GetFragmentEncryptionKey ->
       Deser.pair Deser.string Deser.int64

  let deser_request_o :
  type i o. ProxySession.t -> (i, o) request -> o Deser.t =
    fun session ->
    let ser_version = session.ProxySession.manifest_ser in
    function
    | ListNamespaces -> Deser.counted_list_more Deser.string
    | ListNamespaces2 -> Deser.counted_list_more (Deser.pair Deser.string Deser.string)
    | NamespaceExists -> Deser.bool
    | CreateNamespace -> Deser.unit
    | DeleteNamespace -> Deser.unit

    | ListObjects -> Deser.tuple2 (Deser.counted_list Deser.string) Deser.bool
    | ReadObjectFs -> Deser.unit
    | WriteObjectFs -> Deser.unit
    | WriteObjectFs2 -> Deser.tuple2
                          (Manifest_deser.deser ~ser_version)
                          Deser.x_int64
    | DeleteObject -> Deser.unit
    | GetObjectInfo -> Deser.tuple2 Deser.int64 Checksum_deser.deser'
    | ReadObjectsSlices -> Deser.string
    | ReadObjectsSlices2 ->
       Deser.tuple2
         Deser.string
         (Deser.list (Deser.tuple3
                        Deser.string
                        Deser.string
                        (Deser.tuple2
                           (Manifest_deser.deser ~ser_version)
                           Deser.x_int64)
         ))
    | InvalidateCache -> Deser.unit
    | DropCache -> Deser.unit
    | ProxyStatistics -> ProxyStatistics.deser
    | GetVersion -> Deser.tuple4
                      Deser.int
                      Deser.int
                      Deser.int
                      Deser.string
    | OsdView ->
       let deser_claim =
         Deser.counted_list
           (Deser.tuple2 Deser.string Osd_deser.ClaimInfo.deser) in
       Deser.tuple2
         deser_claim
         (Deser.counted_list
            (Deser.tuple3
               Deser.x_int64
               Osd_deser.OsdInfo.deser_json
               Osd_state.deser_state))
    | GetClientConfig ->
       Alba_arakoon_deser.Config.from_buffer, Alba_arakoon_deser.Config.to_buffer
    | Ping -> Deser.float
    | OsdInfo ->
       Deser.counted_list (Deser.tuple3 Deser.x_int64
                                        Osd_deser.OsdInfo.deser
                                        Capabilities.OsdCapabilities.deser
                          )
    | OsdInfo2 ->
       Deser.counted_list
         (Deser.pair
            Deser.string
            (Deser.counted_list (Deser.tuple3
                                   Deser.x_int64
                                   Osd_deser.OsdInfo.deser
                                   Capabilities.OsdCapabilities.deser
         )))
    | ApplySequence ->
       Deser.list (Deser.tuple3
                     Deser.string
                     Deser.string
                     (Deser.pair
                        (Manifest_deser.deser ~ser_version)
                        Deser.x_int64))
    | ReadObjects ->
       Deser.pair
         Deser.x_int64
         (Deser.list
            (Deser.option
               (Deser.pair
                  (Manifest_deser.deser ~ser_version)
                  Deser.bigstring_slice)))
    | MultiExists ->
       Deser.list Deser.bool
    | GetAlbaId ->
       Deser.string
    | HasLocalFragmentCache ->
       Deser.bool
    | UpdateSession -> Deser.list
                         (Deser.pair
                            Deser.string
                            Deser.string)
    | GetFragmentEncryptionKey ->
       Deser.option Deser.string
end
