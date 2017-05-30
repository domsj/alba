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

let large_value = lazy (String.make (512*1024) 'a')

class type t =
  object
    method finalize : unit
    method get_default_osd_priority : Osd.priority
    method get_osd_claim_info :
             Albamgr_protocol.Protocol.Osd.ClaimInfo.t StringMap.t
    method get_osd_info :
             osd_id:Albamgr_protocol.Protocol.Osd.id ->
             (Nsm_model.OsdInfo.t * Osd_state.t * Capabilities.OsdCapabilities.t) Lwt.t
    method osd_factory :
             Nsm_model.OsdInfo.t ->
             (Osd.osd * (unit -> unit Lwt.t))
               Lwt.t
    method osd_timeout : float
    method osds_info_cache :
             (Albamgr_protocol.Protocol.Osd.id,
              Nsm_model.OsdInfo.t * Osd_state.t * Capabilities.OsdCapabilities.t)
               Hashtbl.t

    method osd_infos :
             ((Albamgr_protocol.Protocol.Osd.id * Nsm_model.OsdInfo.t *
                 Capabilities.OsdCapabilities.t))
               counted_list

    method osds_to_osds_info_cache :
             Albamgr_protocol.Protocol.Osd.id list ->
             (Albamgr_protocol.Protocol.Osd.id,
              Nsm_model.OsdInfo.t)
               Hashtbl.t Lwt.t
    method populate_osds_info_cache : unit Lwt.t
    method propagate_osd_info : ?run_once:bool -> ?delay:float -> unit -> unit Lwt.t
    method seen :
             ?check_claimed:(string -> bool) ->
             ?check_claimed_delay:float -> Discovery.t -> unit Lwt.t
    method with_osd :
             osd_id:Albamgr_protocol.Protocol.Osd.id ->
             (Osd.osd -> 'a Lwt.t) -> 'a Lwt.t

    method get_download_fragment_dedup_cache :
             ((Nsm_model.osd_id * Nsm_model.version) * Osd.namespace_id * string * int * int,
              (Alba_statistics.Statistics.fragment_fetch * Lwt_bytes2.SharedBuffer.t *
                 (Nsm_model.Manifest.t * int64 * string) list,
               [ `AsdError of Asd_protocol.Protocol.Error.t
               | `AsdExn of exn
               | `ChecksumMismatch
               | `FragmentMissing ])
                result Lwt.u list)
               Prelude.Hashtbl.t
  end
