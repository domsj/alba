(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Nsm_model

module Session = struct
  type t = { mutable manifest_ser : int}
  let make () = { manifest_ser = 1}
  let set_manifest_ser t v = t.manifest_ser <- v

end

module Protocol = struct

  type namespace_id = int64 [@@deriving show, yojson]

  module RangeQueryArgs =
    struct
      type 'a t = 'a Range_query_args.RangeQueryArgs.t = {
            first : 'a;
            finc : bool;
            last : ('a * bool) option;
            reverse : bool;
            max : int;
          }

      let to_buffer a_to buf =
        Range_query_args.RangeQueryArgs.to_buffer
          `MaxThenReverse
          a_to buf
      let from_buffer a_from buf =
        Range_query_args.RangeQueryArgs.from_buffer
          `MaxThenReverse
          a_from buf
      let deser a_deser = from_buffer (fst a_deser), to_buffer (snd a_deser)
    end


  type ('request, 'response) query =
    | GetObjectManifestByName : (object_name, Manifest.t option) query
    | GetObjectManifestsByName : (object_name list, Manifest.t option list) query
    | GetObjectManifestById : (object_id, Manifest.t option) query

    | GetGcEpochs : (unit, GcEpochs.t) query

    | ListObjects : (object_name RangeQueryArgs.t,
                     object_name counted_list_more) query
    | ListObjectsById : (object_id RangeQueryArgs.t,
                         Manifest.t counted_list_more) query
    | ListObjectsByOsd : (osd_id * object_id RangeQueryArgs.t,
                          Manifest.t counted_list_more) query
    | ListObjectsByPolicy : ((Policy.policy * object_id) RangeQueryArgs.t,
                             Manifest.t counted_list_more) query

    | MultiExists : (object_name list,
                     bool list) query

    | ListDeviceKeysToBeDeleted : (osd_id * string RangeQueryArgs.t,
                                   string counted_list_more) query
    | GetStats : (unit , NamespaceStats.t) query
    | ListActiveOsds : (osd_id RangeQueryArgs.t, osd_id counted_list_more) query

  type ('request, 'response) update =
    | PutObject :
        (overwrite * Manifest.t * GcEpochs.gc_epoch,
         Manifest.t option) update
    | DeleteObject :
        (overwrite * object_name,
         Manifest.t option) update
    | UpdateObject :
        (object_name * object_id *
         (chunk_id * fragment_id * osd_id option) list *
         GcEpochs.gc_epoch *
         version,
         unit) update

    | DisableGcEpoch : (GcEpochs.gc_epoch, unit) update
    | EnableGcEpoch : (GcEpochs.gc_epoch, unit) update

    | MarkKeysDeleted : ((osd_id * string list) list, unit) update
    | CleanupOsdKeysToBeDeleted : (osd_id, int) update

    | ApplySequence : (Assert.t list * Update.t list, unit) update
    | UpdateObject2 :
        (object_name * object_id
         * FragmentUpdate.t list
         * GcEpochs.gc_epoch * version,
         unit
        ) update

    | UpdatePreset : (Preset.t * Preset.version, unit) update
    | UpdateObject3 :
        (object_name * object_id
         * FragmentUpdate.t list
         * GcEpochs.gc_epoch * version,
         unit
        ) update


  let overwrite_to buf = function
    | Unconditionally -> Llio.int8_to buf 1
    | NoPrevious -> Llio.int8_to buf 2
    | PreviousObjectId object_id ->
      Llio.int8_to buf 3;
      Llio.string_to buf object_id
    | AnyPrevious -> Llio.int8_to buf 4
  let overwrite_from buf =
    match Llio.int8_from buf with
    | 1 -> Unconditionally
    | 2 -> NoPrevious
    | 3 -> PreviousObjectId (Llio.string_from buf)
    | 4 -> AnyPrevious
    | k -> raise_bad_tag "Overwrite" k

  let read_query_request : type req res. (req, res) query -> req Llio.deserializer
    = function
      | GetObjectManifestByName -> Llio.string_from
      | GetObjectManifestsByName -> Llio.list_from Llio.string_from
      | GetObjectManifestById -> Llio.string_from
      | GetGcEpochs -> Llio.unit_from

      | ListObjects -> RangeQueryArgs.from_buffer Llio.string_from
      | ListObjectsById -> RangeQueryArgs.from_buffer Llio.string_from
      | ListObjectsByOsd ->
        Llio.pair_from
          x_int64_from
          (RangeQueryArgs.from_buffer Llio.string_from)
      | ListObjectsByPolicy ->
        RangeQueryArgs.from_buffer
          (Llio.pair_from
             Policy.from_buffer
             Llio.string_from)

      | MultiExists -> Llio.list_from Llio.string_from

      | ListDeviceKeysToBeDeleted ->
        Llio.pair_from
          x_int64_from
          (RangeQueryArgs.from_buffer Llio.string_from)
      | GetStats -> Llio.unit_from
      | ListActiveOsds -> RangeQueryArgs.from_buffer x_int64_from

  let read_update_request : type req res. (req, res) update -> req Llio.deserializer
    = function
      | DisableGcEpoch -> Llio.int64_from
      | EnableGcEpoch -> Llio.int64_from
      | PutObject ->
        Llio.tuple3_from
          overwrite_from
          Manifest.input
          Llio.int64_from
      | DeleteObject ->
        Llio.pair_from
          overwrite_from
          Llio.string_from
      | MarkKeysDeleted ->
        Llio.list_from (Llio.pair_from x_int64_from (Llio.list_from Llio.string_from))
      | UpdateObject -> fun buf ->
        let name = Llio.string_from buf in
        let object_id = Llio.string_from buf in
        let updates =
          Llio.list_from
            (fun buf ->
               let chunk_id = Llio.int_from buf in
               let fragment_id = Llio.int_from buf in
               let osd_id = Llio.option_from x_int64_from buf in
               chunk_id, fragment_id, osd_id)
            buf in
        let gc_epoch = Llio.int64_from buf in
        let version_id = Llio.int_from buf in
        (name, object_id, updates, gc_epoch, version_id)
      | CleanupOsdKeysToBeDeleted ->
        x_int64_from
      | ApplySequence ->
         Llio.pair_from
           (Llio.list_from Assert.from_buffer)
           (Llio.list_from Update.from_buffer)
      | UpdatePreset ->
         Llio.pair_from
           Preset.from_buffer
           Llio.int64_from
      | UpdateObject2 ->
         Llio.tuple5_from
           Llio.string_from
           Llio.string_from
           (Llio.list_from FragmentUpdate.from_buffer_v0)
           Llio.int64_from
           Llio.int_from
      | UpdateObject3 ->
         Llio.tuple5_from
           Llio.string_from
           Llio.string_from
           (Llio.list_from FragmentUpdate.from_buffer)
           Llio.int64_from
           Llio.int_from

  let write_query_request : type req res. (req, res) query -> req Llio.serializer
    = function
      | GetObjectManifestByName -> Llio.string_to
      | GetObjectManifestsByName -> Llio.list_to Llio.string_to
      | GetObjectManifestById -> Llio.string_to

      | GetGcEpochs -> Llio.unit_to

      | ListObjects -> RangeQueryArgs.to_buffer Llio.string_to
      | ListObjectsById -> RangeQueryArgs.to_buffer Llio.string_to
      | ListObjectsByOsd ->
        Llio.pair_to
          x_int64_to
          (RangeQueryArgs.to_buffer Llio.string_to)
      | ListObjectsByPolicy ->
        RangeQueryArgs.to_buffer
          (Llio.pair_to
             Policy.to_buffer
             Llio.string_to)

      | MultiExists -> Llio.list_to Llio.string_to

      | ListDeviceKeysToBeDeleted ->
        Llio.pair_to
          x_int64_to
          (RangeQueryArgs.to_buffer Llio.string_to)

      | GetStats -> Llio.unit_to
      | ListActiveOsds -> RangeQueryArgs.to_buffer x_int64_to

  let write_update_request :
  type req res. Session.t -> (req, res) update -> req Llio.serializer
    = fun session ->
    let version = session.Session.manifest_ser in
    function
    | DisableGcEpoch -> Llio.int64_to
    | EnableGcEpoch -> Llio.int64_to
    | PutObject ->
       Llio.tuple3_to
         overwrite_to
         (Manifest.to_buffer ~version)
         Llio.int64_to
    | DeleteObject ->
       Llio.pair_to
         overwrite_to
         Llio.string_to
    | MarkKeysDeleted ->
       Llio.list_to (Llio.pair_to x_int64_to (Llio.list_to Llio.string_to))
    | UpdateObject -> fun buf (name, object_id, updates, gc_epoch, version_id) ->
                      Llio.string_to buf name;
                      Llio.string_to buf object_id;
                      Llio.list_to
                        (fun buf (chunk_id, fragment_id, device_id) ->
                          Llio.int_to buf chunk_id;
                          Llio.int_to buf fragment_id;
                          Llio.option_to x_int64_to buf device_id)
                        buf
                        updates;
                      Llio.int64_to buf gc_epoch;
                      Llio.int_to buf version_id
    | CleanupOsdKeysToBeDeleted ->
       x_int64_to
    | ApplySequence ->
       Llio.pair_to
         (Llio.list_to Assert.to_buffer)
         (Llio.list_to (Update.to_buffer ~manifest_version:version))
    | UpdatePreset ->
       Llio.pair_to
         (Preset.to_buffer ~version:2)
         Llio.int64_to
    | UpdateObject2 ->
       Llio.tuple5_to
         Llio.string_to
         Llio.string_to
         (Llio.list_to FragmentUpdate.to_buffer_v0)
         Llio.int64_to
         Llio.int_to
    | UpdateObject3 ->
       Llio.tuple5_to
         Llio.string_to
         Llio.string_to
         (Llio.list_to FragmentUpdate.to_buffer)
         Llio.int64_to
         Llio.int_to

  let write_query_response :
  type req res. Session.t ->
       (req, res) query ->
       res Llio.serializer
    = fun session ->
    let version = session.Session.manifest_ser in
    let manifest_to = Manifest.to_buffer ~version in
    function
    | GetObjectManifestByName -> Llio.option_to manifest_to
    | GetObjectManifestsByName -> Llio.list_to (Llio.option_to manifest_to)
    | GetObjectManifestById -> Llio.option_to manifest_to
    | GetGcEpochs -> GcEpochs.output
    | ListObjects -> counted_list_more_to Llio.string_to
    | ListObjectsById -> counted_list_more_to manifest_to
    | ListObjectsByPolicy -> counted_list_more_to manifest_to
    | ListObjectsByOsd -> counted_list_more_to manifest_to

    | MultiExists -> Llio.list_to Llio.bool_to

    | ListDeviceKeysToBeDeleted ->
       counted_list_more_to Llio.string_to

    | GetStats -> NamespaceStats.to_buffer

    | ListActiveOsds -> counted_list_more_to x_int64_to

  let write_update_response :
  type req res. Session.t ->
       (req, res) update ->
       res Llio.serializer
    =
    fun session ->
    let version = session.Session.manifest_ser in
    let manifest_to = Manifest.to_buffer ~version in
    function
      | DisableGcEpoch -> Llio.unit_to
      | EnableGcEpoch -> Llio.unit_to
      | PutObject -> Llio.option_to manifest_to
      | DeleteObject -> Llio.option_to manifest_to
      | UpdateObject -> Llio.unit_to
      | MarkKeysDeleted -> Llio.unit_to
      | CleanupOsdKeysToBeDeleted -> Llio.int_to
      | ApplySequence -> Llio.unit_to
      | UpdatePreset -> Llio.unit_to
      | UpdateObject2 -> Llio.unit_to
      | UpdateObject3 -> Llio.unit_to

  let read_query_response : type req res. (req, res) query -> res Llio.deserializer
    = function
      | GetObjectManifestByName ->
        Llio.option_from Manifest.input
      | GetObjectManifestsByName ->
        Llio.list_from (Llio.option_from Manifest.input)
      | GetObjectManifestById ->
        Llio.option_from Manifest.input

      | GetGcEpochs ->
        GcEpochs.input

      | ListObjects ->
        counted_list_more_from Llio.string_from
      | ListObjectsById ->
        counted_list_more_from Manifest.from_buffer
      | ListObjectsByOsd ->
        counted_list_more_from Manifest.from_buffer
      | ListObjectsByPolicy ->
        counted_list_more_from Manifest.from_buffer

      | MultiExists -> Llio.list_from Llio.bool_from

      | ListDeviceKeysToBeDeleted ->
        counted_list_more_from Llio.string_from

      | GetStats -> NamespaceStats.from_buffer

      | ListActiveOsds -> counted_list_more_from x_int64_from

  let read_update_response : type req res. (req, res) update -> res Llio.deserializer
    = function
      | DisableGcEpoch -> Llio.unit_from
      | EnableGcEpoch -> Llio.unit_from
      | PutObject -> Llio.option_from Manifest.input
      | DeleteObject -> Llio.option_from Manifest.input
      | UpdateObject -> Llio.unit_from
      | MarkKeysDeleted -> Llio.unit_from
      | CleanupOsdKeysToBeDeleted -> Llio.int_from
      | ApplySequence -> Llio.unit_from
      | UpdatePreset -> Llio.unit_from
      | UpdateObject2 -> Llio.unit_from
      | UpdateObject3 -> Llio.unit_from

end
