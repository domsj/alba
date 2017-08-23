(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Slice
open Lwt_bytes2
open Recovery_info
open Alba_statistics
open Alba_client_common
open Alba_client_errors
open Lwt.Infix
open Nsm_model
module Osd_sec = Osd

let fragment_multiple = Fragment_size_helper.fragment_multiple

let upload_packed_fragment_data
      (osd_access : Osd_access_type.t)
      ~namespace_id ~object_id
      ~version_id ~chunk_id ~fragment_id
      ~packed_fragment ~checksum
      ~gc_epoch
      ~recovery_info_blob
      ~osd_id
  =
  let open Osd_keys in
  Lwt_log.debug_f
    "upload_packed_fragment_data %i bytes @ %nX (chunk %i, frag %i) to osd:%Li"
    (Lwt_bytes.length packed_fragment) (Lwt_bytes.raw_address packed_fragment)
    chunk_id fragment_id osd_id
  >>= fun () ->
  let data_key = AlbaInstance.fragment
                   ~object_id ~version_id
                   ~chunk_id ~fragment_id
                  |> Slice.wrap_string
  in
  let set_data =
    Osd.Update.set
      data_key
      (Asd_protocol.Blob.Lwt_bytes packed_fragment)
      checksum false
  in
  let set_recovery_info =
    Osd.Update.set
      (Slice.wrap_string
         (AlbaInstance.fragment_recovery_info
            ~object_id ~version_id
            ~chunk_id ~fragment_id))
      (* TODO do add some checksum *)
      recovery_info_blob Checksum.NoChecksum true
  in
  let set_gc_tag =
    Osd.Update.set_string
      (AlbaInstance.gc_epoch_tag
         ~gc_epoch
         ~object_id ~version_id
         ~chunk_id ~fragment_id)
      "" Checksum.NoChecksum true
  in
  let do_upload () =
    let msg = Printf.sprintf "do_upload ~osd_id:%Li" osd_id in
    Lwt_extra2.with_timeout ~msg (osd_access # osd_timeout)
      (fun () ->
       osd_access # with_osd
         ~osd_id
         (fun client ->
          (client # namespace_kvs namespace_id) # apply_sequence
                 (osd_access # get_default_osd_priority)
                 []
                 [ set_data;
                   set_recovery_info;
                   set_gc_tag; ]))
  in

  do_upload () >>= fun apply_result ->
  osd_access # get_osd_info ~osd_id >>= fun (_, state, _) ->
  match apply_result with
  | Ok r ->
     Osd_state.add_write state;
     let r' = List.assoc' Slice.equal data_key r in
     Lwt.return r'
  | Error exn ->
     let open Asd_protocol.Protocol in
     Error.lwt_fail exn

let upload_chunk
      osd_access
      ~namespace_id
      ~object_id ~object_name
      ~chunk ~chunk_id ~chunk_size
      ~k ~m ~w' ~min_fragment_count
      ~compression ~encryption
      ~fragment_checksum_algo
      ~version_id ~gc_epoch
      ~object_info_o
      ~osds
      ~(fragment_cache : Fragment_cache.cache)
      ~cache_on_write
      ~upload_slack :
      ((Alba_statistics.Statistics.fragment_upload * Fragment.t) Lwt.t list
       * (Manifest.t * int64 * string) list
       * Checksum.t list
       * int list
       * bytes option list)
        Lwt.t
  =

  let t0 = Unix.gettimeofday () in

  Fragment_helper.chunk_to_packed_fragments
    ~object_id ~chunk_id
    ~chunk ~chunk_size
    ~k ~m ~w'
    ~compression ~encryption ~fragment_checksum_algo
  >>= fun (unpacked_data_fragments, fragments_with_id) ->

  let t_add_to_fragment_cache =
    if cache_on_write
    then
      Lwt_list.mapi_p
        (fun fragment_id unpacked_data_fragment ->
         let cache_key =
           Fragment_cache_keys.make_key
             ~object_id
             ~chunk_id
             ~fragment_id
         in
         fragment_cache # add
                        namespace_id
                        cache_key
                        unpacked_data_fragment
        )
        unpacked_data_fragments
      >|= List.flatten_unordered
    else
      Lwt.return []
  in

  let __shared_packed_fragments = ref (k+m) in
  let get_checksum    (_, _, (_ , _, _, checksum,   _)) = checksum in
  let get_ctr         (_, _, (_ , _, _,        _, ctr)) = ctr in
  let get_packed_size (_, _, (pf, _, _,        _,   _)) =
    Lwt_bytes.length pf
  in
  Lwt.finalize
    (fun () ->
     let packed_fragment_sizes = List.map get_packed_size fragments_with_id in
     let fragment_checksums    = List.map get_checksum    fragments_with_id in
     let fragment_ctrs         = List.map get_ctr         fragments_with_id in

     let upload_fragment_and_finalize
           ((fragment_id,
             fragment,
             (packed_fragment,
              t_compress_encrypt,
              t_hash,
              checksum,
              fragment_ctr)),
            osd_id_o)
       =
       Lwt.finalize
         (fun () ->
           with_timing_lwt
             (fun () ->
               match osd_id_o with
               | None -> Lwt.return None
               | Some osd_id ->

                  RecoveryInfo.make
                    ~object_name
                    ~object_id
                    object_info_o
                    encryption
                    chunk_size
                    packed_fragment_sizes
                    fragment_checksums
                    fragment_ctr
                  >>= fun recovery_info_slice ->

                  upload_packed_fragment_data
                    osd_access
                    ~namespace_id
                    ~osd_id
                    ~object_id ~version_id
                    ~chunk_id ~fragment_id
                    ~packed_fragment ~checksum
                    ~gc_epoch
                    ~recovery_info_blob:(Asd_protocol.Blob.Slice recovery_info_slice))
           >>= fun (t_store, (fnro: string option)) ->
           let packed_len = Lwt_bytes.length packed_fragment in
           let t_fragment =
             let open Statistics in
             {
               size_orig = Bigstring_slice.length fragment;
               size_final = packed_len;
               compress_encrypt = t_compress_encrypt;
               hash = t_hash;
               osd_id_o;
               store_osd = t_store;
               total = (Unix.gettimeofday () -. t0)
             }
           in

           let res =
             Fragment.make
               osd_id_o version_id
               checksum packed_len fragment_ctr
               fnro
           in
           Lwt_log.debug_f "fragment_uploaded %i bytes @ %nX (%i,%i) of (%S %S) to %s"
                          packed_len (Lwt_bytes.raw_address packed_fragment)
                          chunk_id fragment_id object_name object_id ([%show : int64 option] osd_id_o)
           >>= fun ()->
           Lwt.return (t_fragment, res)
         )
         (fun () ->
           if k <> 1
           then
             let msg = Printf.sprintf "destroy packed_fragment namespace %Li chunk %i fragment %i of (%S %S)"
                         namespace_id chunk_id fragment_id object_name object_id in
               Lwt_bytes.unsafe_destroy ~msg:msg packed_fragment
           else
             begin
               decr __shared_packed_fragments;
               if !__shared_packed_fragments = 0
               then Lwt_bytes.unsafe_destroy packed_fragment
             end;
           Lwt.return_unit
         )
     in
     let test = fun (_, f) -> Fragment.has_osd f in
     Lwt_extra2.first_n
       ~count:min_fragment_count
       ~slack:upload_slack
       ~test
       upload_fragment_and_finalize
       (List.combine fragments_with_id osds)
     >>= fun (success, make_results)  ->
     if not success
     then Lwt.fail_with (Printf.sprintf "chunk %i failed name: [%s] id: [%s]" chunk_id object_name object_id)
     else
       begin
         t_add_to_fragment_cache >>= fun mfs ->
         Lwt.return (make_results, mfs,
                     fragment_checksums,
                     packed_fragment_sizes,
                     fragment_ctrs)
       end
    )
    (fun () ->
      t_add_to_fragment_cache >>= fun _ ->
      Lwt.return_unit
    )

let upload_object''
      (nsm_host_access : Nsm_host_access.nsm_host_access)
      osd_access
      get_preset_info
      get_namespace_osds_info_cache
      ~object_t0 ~timestamp
      ~namespace_id
      ~(object_name : string)
      ~(object_reader : Object_reader.reader)
      ~(checksum_o: Checksum.t option)
      ~(object_id_hint: string option)
      ~fragment_cache
      ~cache_on_write
      ~upload_slack
  =

  (* TODO
          - retry/error handling/etc where needed
   *)
  (* nice to haves (for performance)
         - upload of multiple chunks could be done in parallel
         - avoid some string copies *)

  object_reader # reset >>= fun () ->

  nsm_host_access # get_namespace_info ~namespace_id >>= fun (_, ns_info, _, _) ->
  let open Albamgr_protocol in
  get_preset_info ~preset_name:ns_info.Protocol.Namespace.preset_name
  >>= fun preset ->


  nsm_host_access # get_gc_epoch ~namespace_id >>= fun gc_epoch ->

  let policies, w, max_fragment_size,
      compression, fragment_checksum_algo,
      allowed_checksum_algos, verify_upload,
      encryption =
    let open Preset in
    preset.policies, preset.w,
    preset.fragment_size,
    preset.compression, preset.fragment_checksum_algo,
    preset.object_checksum.allowed, preset.object_checksum.verify_upload,
    preset.fragment_encryption
  in
  let w' = Encoding_scheme.w_as_int w in

  Lwt.catch
    (fun () ->
     get_namespace_osds_info_cache ~namespace_id >>= fun osds_info_cache' ->
     let p =
       get_best_policy_exn
         policies
         osds_info_cache' in
     Lwt.return (p, osds_info_cache'))
    (function
      | Error.Exn Error.NoSatisfiablePolicy ->
         nsm_host_access # refresh_namespace_osds ~namespace_id >>= fun (_, osds) ->
         Lwt_log.debug_f "got namespace osds for namespace_id=%Li: %s" namespace_id ([%show: int64 list] osds) >>= fun () ->
         get_namespace_osds_info_cache ~namespace_id >>= fun osds_info_cache' ->
         let p =
           get_best_policy_exn
             policies
             osds_info_cache' in
         Lwt.return (p, osds_info_cache')
      | exn ->
         Lwt.fail exn)
  >>= fun (((k, m, min_fragment_count, max_disks_per_node),
            actual_fragment_count, _),
           osds_info_cache') ->

  let storage_scheme, encrypt_info =
    Storage_scheme.EncodeCompressEncrypt
      (Encoding_scheme.RSVM (k, m, w),
       compression),
    Encrypt_info_helper.from_encryption encryption
  in

  let object_checksum_algo =
    let open Preset in
    match checksum_o with
    | None -> preset.object_checksum.default
    | Some checksum ->
       let checksum_algo = Checksum.algo_of checksum in

       if not (List.mem checksum_algo allowed_checksum_algos)
       then Error.failwith Error.ChecksumAlgoNotAllowed;

       if verify_upload
       then checksum_algo
       else Checksum.Algo.NO_CHECKSUM
  in
  let object_hash = Hashes.make_hash object_checksum_algo in

  let version_id = 0 in

  Lwt_log.debug_f
    "Choosing %i devices from %i candidates for a (%i,%i,%i,%i) policy"
    actual_fragment_count
    (Hashtbl.length osds_info_cache')
    k m min_fragment_count max_disks_per_node
  >>= fun () ->

  let target_devices =
    Choose.choose_devices
      actual_fragment_count
      osds_info_cache' in

  if actual_fragment_count <> List.length target_devices
  then failwith
         (Printf.sprintf
            "Cannot upload object with k=%i,m=%i,actual_fragment_count=%i when only %i active devices could be found for this namespace"
            k m actual_fragment_count (List.length target_devices));

  let target_osds =
    let no_dummies = k + m - actual_fragment_count in
    let dummies = List.map (fun _ -> None) Int.(range 0 no_dummies) in
    List.append
      (List.map (fun (osd_id, _) -> Some osd_id) target_devices)
      dummies
  in

  let object_id =
    match object_id_hint with
    | None -> get_random_string 32
    | Some hint -> hint
  in

  object_reader # length >>= fun object_length ->

  let desired_chunk_size = Fragment_size_helper.determine_chunk_size ~object_length ~max_fragment_size ~k in

  let fold_chunks chunk =

    let rec inner
              acc_fragment_ts
              acc_chunk_sizes
              acc_fragments_info
              acc_mfs
              total_size
              chunk_times
              hash_time
              chunk_id
      =
      let t0_chunk = Unix.gettimeofday () in
      let chunk_size' = min desired_chunk_size (object_length - total_size) in
      let total_size' = total_size + chunk_size' in
      let has_more = total_size' < object_length in

      Lwt_log.debug_f
        "chunk_size' = %i, total_size'=%i, has_more=%b, chunk_id=%i, object_length=%i, desired_chunk_size=%i"
        chunk_size'
        total_size'
        has_more
        chunk_id
        object_length
        desired_chunk_size
      >>= fun () ->
      with_timing_lwt
        (fun () -> object_reader # read chunk_size' chunk)
      >>= fun (read_data_time, ()) ->


      with_timing_lwt
        (fun () ->
         object_hash # update_lwt_bytes_detached chunk 0 chunk_size')
      >>= fun (hash_time', ()) ->

      let hash_time' = hash_time +. hash_time' in

      let object_info_o =
        if has_more
        then None
        else Some RecoveryInfo.({
                                   storage_scheme;
                                   size = Int64.of_int total_size';
                                   checksum = object_hash # final ();
                                   timestamp;
                                 })
      in

      let chunk_size_with_padding =
        let kf = fragment_multiple * k in
        if chunk_size' mod kf = 0
           || k = 1         (* no padding needed/desired for replication *)
        then chunk_size'
        else begin
            let s = ((chunk_size' / kf) + 1) * kf in
            (* the fill here prevents leaking information in the padding bytes *)
            Lwt_bytes.fill chunk chunk_size' (s - chunk_size') (Char.chr 0);
            s
          end
      in
      let chunk' = Lwt_bytes.extract chunk 0 chunk_size_with_padding in

      Lwt.finalize
        (fun () ->
         upload_chunk
           osd_access
           ~namespace_id
           ~object_id ~object_name
           ~chunk:chunk' ~chunk_size:chunk_size_with_padding
           ~chunk_id
           ~k ~m ~w' ~min_fragment_count
           ~compression ~encryption ~fragment_checksum_algo
           ~version_id ~gc_epoch
           ~object_info_o
           ~osds:target_osds
           ~fragment_cache
           ~cache_on_write
           ~upload_slack:(if has_more then 0.0 else upload_slack)
        )
        (fun () ->
         Lwt_bytes.unsafe_destroy ~msg:"Lwt.finalize upload_chunk" chunk';
         Lwt.return ())
      >>= fun (fragment_ts,
               mfs,
               fragment_checksums,
               packed_fragment_sizes,
               fragment_ctrs)  ->
      let fragment_states = List.map Lwt.state fragment_ts in
      let fragment_info =
        List.map4i
          (fun i state fragment_checksum packed_fragment_size fragment_ctr ->
            match state with
            | Lwt.Return ((stats, fragment) as res) ->
               Lwt_log.ign_debug_f "i=%i =>%s " i
                                   (Statistics.show_fragment_upload stats);
               res
            | Lwt.Fail exn ->
               Lwt_log.ign_warning_f "fragment upload failed:%s"
                                     (Printexc.to_string exn);
               let stats =
                 Statistics.({
                                size_orig = 0;
                                size_final = 0;
                                compress_encrypt = 0.0;
                                hash = 0.0;
                                osd_id_o = None;
                                store_osd = 0.0;
                                total = 0.0;
                 })
               in
               let fragment =
                 Fragment.make None version_id
                          fragment_checksum
                          packed_fragment_size
                          fragment_ctr
                          None
               in
               (stats, fragment)
            | Lwt.Sleep ->
               (* for now, assume these (will) have failed *)
               let stats =
                 Statistics.({
                                size_orig = 0;
                                size_final = 0;
                                compress_encrypt = 0.0;
                                hash = 0.0;
                                osd_id_o = None;
                                store_osd = 0.0;
                                total = 0.0;
                 })
               in
               let fragment =
                 Fragment.make
                           None version_id
                           fragment_checksum
                           packed_fragment_size
                           fragment_ctr None
               in
               (stats, fragment)
          ) fragment_states fragment_checksums packed_fragment_sizes
            fragment_ctrs
      in
      let t_fragments, fragment_info = List.split fragment_info in

      let acc_chunk_sizes' = (chunk_id, chunk_size_with_padding) :: acc_chunk_sizes in
      let acc_fragments_info' = fragment_info :: acc_fragments_info in

      let acc_mfs' = List.rev_append mfs acc_mfs in

      let t_chunk = Statistics.({
                                   read_data = read_data_time;
                                   fragments = t_fragments;
                                   total = Unix.gettimeofday () -. t0_chunk;
                                 }) in

      let chunk_times' = t_chunk :: chunk_times in
      let acc_fragment_ts' = fragment_ts :: acc_fragment_ts in
      if has_more
      then
        inner
          acc_fragment_ts'
          acc_chunk_sizes'
          acc_fragments_info'
          acc_mfs'
          total_size'
          chunk_times'
          hash_time'
          (chunk_id + 1)
      else
        Lwt.return ((List.rev acc_fragment_ts',
                     List.rev acc_chunk_sizes',
                     List.rev acc_fragments_info',
                     acc_mfs'
                    ),
                    total_size',
                    List.rev chunk_times',
                    hash_time')
    in
    inner [] [] [] [] 0 [] 0. (0:chunk_id) in

  let chunk = Lwt_bytes.create desired_chunk_size in
  Lwt.finalize
    (fun () -> fold_chunks chunk)
    (fun () -> Lwt_bytes.unsafe_destroy ~msg:"Lwt.finalize fold_chunks" chunk;
               Lwt.return ())
  >>= fun ((fragment_state_layout, chunk_sizes', fragments, chunk_mfs),
           size, chunk_times, hash_time) ->

  (* all fragments have been stored
         make a manifest and store it in the namespace manager *)

  let object_checksum = object_hash # final () in
  let checksum =
    match checksum_o with
    | None -> object_checksum
    | Some checksum ->
       if verify_upload &&
            checksum <> object_checksum
       then Error.failwith Error.ChecksumMismatch;
       checksum
  in
  let chunk_sizes = List.map snd chunk_sizes' in
  let manifest =
    Manifest.make
      ~name:object_name
      ~object_id
      ~storage_scheme
      ~encrypt_info
      ~chunk_sizes
      ~checksum
      ~size:(Int64.of_int size)
      ~fragments
      ~version_id
      ~max_disks_per_node
      ~timestamp
  in
  let almost_t_object t_store_manifest =
    Statistics.({
                   size;
                   hash = hash_time;
                   chunks = chunk_times;
                   store_manifest = t_store_manifest;
                   total = Unix.gettimeofday () -. object_t0;
    })
  in
  Lwt.return (manifest, chunk_mfs, almost_t_object, gc_epoch,
              fragment_state_layout)

let cleanup_gc_tags
      (osd_access : Osd_access_type.t)
      mf
      gc_epoch
      ~namespace_id
  =
  (* clean up gc tags we left behind on the osds,
   * if it fails that's no problem, the gc will
   * come and clean it up later *)
  Lwt.catch
    (fun () ->
     Lwt_list.iteri_p
       (fun chunk_id chunk_locs ->
        Lwt_list.iteri_p
          (fun fragment_id f  ->
           let (osd_id_o, version_id) = Fragment.loc_of f in
           match osd_id_o with
           | None -> Lwt.return ()
           | Some osd_id ->
              osd_access # with_osd
                         ~osd_id
                         (fun osd ->
                          let remove_gc_tag =
                            Osd.Update.delete_string
                              (Osd_keys.AlbaInstance.gc_epoch_tag
                                 ~gc_epoch
                                 ~object_id:mf.Manifest.object_id
                                 ~version_id
                                 ~chunk_id
                                 ~fragment_id)
                          in
                          (osd # namespace_kvs namespace_id) # apply_sequence
                                                             (osd_access # get_default_osd_priority)
                                                             [] [ remove_gc_tag; ] >>= fun _ ->
                          Lwt.return ()))
          chunk_locs)
       mf.Manifest.fragments)
    (fun exn -> Lwt_log.debug_f ~exn "Error while cleaning up gc tags")
  |> Lwt.ignore_result


let store_manifest_epilogue
      (osd_access : Osd_access_type.t)
      (nsm_host_access : Nsm_host_access.nsm_host_access)
      manifest_cache
      manifest
      gc_epoch
      ~namespace_id
      t_object
      ~epilogue_delay
      fragment_state_layout
  =
  let () = cleanup_gc_tags osd_access manifest gc_epoch ~namespace_id in

  let object_name = manifest.Manifest.name in
  Lwt_log.ign_debug_f
    ~section:Statistics.section
    "Uploaded object %S in namespace %Li with the following timings: %s"
    object_name namespace_id (Statistics.show_object_upload t_object);

  let open Manifest_cache in
  ManifestCache.add
    manifest_cache
    namespace_id object_name manifest;

  let upload_epilogue () =
    Lwt_log.debug_f "epilogue for object:%S" object_name >>= fun () ->
    Lwt.catch
    (fun () ->
      begin
        (match epilogue_delay with
         | None   -> Lwt.return_unit
         | Some d ->
            Lwt_log.debug_f "epilogue_delay: sleeping %f" d >>= fun () ->
            Lwt_unix.sleep d
        )
        >>= fun () ->
        Lwt_list.map_s
          (fun fragment_ts ->
            Lwt_extra2.join_threads_ignore_errors fragment_ts >>= fun () ->
            let last_states = List.map Lwt.state fragment_ts in
            let osd_id_os =
              List.map
                (function
                 | Lwt.Return (stats, fragment) ->
                    (Fragment.osd_of fragment, Fragment.fnr_of fragment)
                 | _ -> (None,None)
                ) last_states
            in
            Lwt.return osd_id_os
          )
          fragment_state_layout
        >>= fun locations ->
        let side_by_side =
          Layout.map2 (fun a b -> (a,b))
            locations
            (manifest.Manifest.fragments)
        in
        let updates =
          let r = ref [] in
          List.iteri
            (fun chunk_id chunk ->
              List.iteri
                (fun fragment_id ((new_o,new_fnr) , old_f) ->
                  let old_o, _old_version = Fragment.loc_of old_f in
                  let old_ctr = Fragment.ctr_of old_f in
                  match new_o, old_o with
                  | None, Some _ -> failwith "new is None ?"
                  | Some x,Some y -> assert (x=y);
                  | None, None   -> ()

                  | Some osd_id, None ->
                     let update =
                       FragmentUpdate.make
                         chunk_id fragment_id (Some osd_id)
                         None old_ctr new_fnr
                     in
                     let () = r := update :: !r in ()
                ) chunk
            ) side_by_side;
          !r
        in
        if updates = []
        then Lwt_log.debug_f "epilogue:nothing to do for object:%S" object_name
        else
          let open Manifest in
          begin
            nsm_host_access # get_nsm_by_id ~namespace_id >>= fun client ->
            client # update_manifest
                   ~object_name
                   ~object_id:manifest.object_id
                   updates
                   ~gc_epoch
                   ~version_id:0
            >>= fun () ->
            Lwt_log.debug_f
              "epilogue:successfully updated object:%S with updates:%s"
              object_name
              ([%show : FragmentUpdate.t list] updates)
            >>= fun () ->
            let manifest' =
              { manifest with
                fragments =
                  Layout.map_indexed
                    (fun chunk_id fragment_id old_fragment  ->
                      let old_osd = Fragment.osd_of old_fragment in
                      let new_osd =
                        match old_osd with
                        | None ->
                           begin
                             let open FragmentUpdate in
                             let update =
                               List.find
                                 (fun fu ->
                                   fu.chunk_id = chunk_id
                                   && fu.fragment_id = fragment_id
                                 ) updates
                             in
                             match update with
                             | Some fu -> fu.osd_id_o
                             | _ -> None
                           end
                        | _ -> old_osd
                      in
                      let open Fragment in
                      { old_fragment with osd = new_osd }
                    ) manifest.fragments
              }
            in
            ManifestCache.add
              manifest_cache namespace_id object_name manifest';
            Lwt.return ()
          end
      end)

    (fun exn -> Lwt_log.info ~exn "failure in epilogue")
  in
  Lwt.ignore_result (upload_epilogue())


let store_manifest
      (nsm_host_access : Nsm_host_access.nsm_host_access)
      (osd_access : Osd_access_type.t)
      manifest_cache
      ~namespace_id
      ~allow_overwrite
      ~epilogue_delay
      (manifest, chunk_fidmos, almost_t_object, gc_epoch,
       fragment_state_layout)
  =
  let object_name = manifest.Manifest.name in
  let store_manifest () =
    nsm_host_access # get_nsm_by_id ~namespace_id >>= fun client ->
    client # put_object
           ~allow_overwrite
           ~manifest
           ~gc_epoch
  in
  with_timing_lwt
    (fun () ->
     Lwt.catch
       store_manifest
       (fun exn ->
        Manifest_cache.ManifestCache.remove
          manifest_cache
          namespace_id object_name;
        Lwt.fail exn))
  >>= fun (t_store_manifest, old_manifest_o) ->

  let t_object = almost_t_object t_store_manifest in

  store_manifest_epilogue
    osd_access
    nsm_host_access
    manifest_cache
    manifest
    gc_epoch
    ~namespace_id
    t_object
    fragment_state_layout
    ~epilogue_delay;

  Lwt.return (manifest, chunk_fidmos, t_object, namespace_id)


let _upload_with_retry
      nsm_host_access
      (preset_cache : Alba_client_preset_cache.preset_cache)
      ~namespace_id
      do_upload
      ?(timestamp = Unix.gettimeofday ())
      (message : string lazy_t)
  =
  Lwt.catch
    (fun () -> do_upload timestamp)
    (fun exn ->

      let timestamp = match exn with
        | Err.Nsm_exn (Err.Old_timestamp, payload) ->
           (* if the upload failed due to the timestamp being not
             recent enough we should retry with a more recent one...

             (ideally we should only overwrite the recovery info,
             so this is a rather brute approach. but for an
             exceptional situation that's ok.)
            *)
           (deserialize Llio.float_from payload) +. 0.1
        | _ ->
           timestamp
      in
      begin
        let open Err in
        match exn with
        | Nsm_exn (err, msg) ->
           Lwt_log.debug_f "upload_exception %s" msg >>= fun () ->
           begin match err with
           | Inactive_osd ->
              Lwt_log.info_f
                "%s failed due to inactive (decommissioned) osd, retrying..."
                (Lazy.force message)
              >>= fun () ->
              nsm_host_access # refresh_namespace_osds ~namespace_id >>= fun (_, osds) ->
              Lwt_log.debug_f "got namespace osds for namespace_id=%Li: %s" namespace_id ([%show: int64 list] osds)

           | Too_many_disks_per_node
           | Preset_violated
           | Invalid_bucket ->
              nsm_host_access # get_namespace_info ~namespace_id >>= fun (_, ns_info, _, _) ->
              let open Albamgr_protocol.Protocol in
              preset_cache # refresh ~preset_name:ns_info.Namespace.preset_name
           | Unknown
           | Old_plugin_version
           | Unknown_operation
           | Inconsistent_read
           | Namespace_id_not_found
           | InvalidVersionId
           | Overwrite_not_allowed
           | Assert_failed
           | Insufficient_fragments
           | Object_not_found ->
              Lwt.fail exn

           | Not_master
           | Old_timestamp
           | Invalid_gc_epoch
           | Invalid_fragment_spread
           | Non_unique_object_id ->
              Lwt.return ()
           end
        | Alba_client_errors.Error.Exn e ->
           Lwt_log.debug_f "%s failed with:%s" (Lazy.force message) (Error.show e)
        | _ ->
           Lwt.return ()
      end >>= fun () ->
      Lwt_log.debug_f ~exn "Exception during %s, retrying once" (Lazy.force message) >>= fun () ->
      do_upload timestamp
    )


let upload_object'
      ~epilogue_delay
      nsm_host_access osd_access
      manifest_cache
      (preset_cache : Alba_client_preset_cache.preset_cache)
      get_namespace_osds_info_cache
      ~namespace_id
      ~object_name
      ~object_reader
      ~checksum_o
      ~allow_overwrite
      ~object_id_hint
      ~fragment_cache
      ~cache_on_write
      ?timestamp
      ~upload_slack
  =

  let object_t0 = Unix.gettimeofday () in
  let do_upload timestamp =
    upload_object''
      nsm_host_access
      osd_access
      (preset_cache # get)
      get_namespace_osds_info_cache
      ~object_t0 ~timestamp
      ~object_name
      ~namespace_id
      ~object_reader
      ~checksum_o
      ~object_id_hint
      ~fragment_cache
      ~cache_on_write
      ~upload_slack
    >>=
      store_manifest
        ~epilogue_delay
        nsm_host_access
        osd_access
        manifest_cache
        ~namespace_id
        ~allow_overwrite
  in
  _upload_with_retry
    nsm_host_access
    preset_cache
    ~namespace_id
    do_upload
    ?timestamp
    (lazy (Printf.sprintf "Upload of %S" object_name))
