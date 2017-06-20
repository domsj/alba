(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Lwt.Infix
open Proxy_protocol
open Protocol
open Range_query_args


class proxy_client fd session =
  let buffer = Lwt_bytes.create 1024 |> ref in

  let with_response tag_name deserializer f =
    Net_fd.with_message_buffer_from
      fd buffer None
      ~max_buffer_size:16500
      (fun ~buffer ~offset ~message_length ~extra_bytes ->

       (* currently we don't expect any extra bytes here
        * (to be returned for proxy operations that this client knows about)
        *)
       assert (extra_bytes = 0);

       let module L = Llio2.ReadBuffer in
       let res_buf = L.make_buffer buffer ~offset ~length:message_length in

       Lwt_log.debug_f
         "proxy client read response of size %i for %s"
         message_length tag_name
       >>= fun () ->

       match Llio2.ReadBuffer.int_from res_buf with
       | 0 ->
          f (deserializer res_buf)
       | err ->
          let err_string = Llio2.ReadBuffer.string_from res_buf in
          Lwt_log.debug_f "Proxy client operation %s received error from server: %s"
                          tag_name err_string
          >>= fun () ->
          Error.lwt_failwith ~payload:err_string (Error.int2err err))
  in
  let do_request code serialize_request request response_deserializer f =
    let tag_name = code_to_txt code in
    Lwt_log.debug_f "proxy_client: %s" tag_name >>= fun () ->

    let module Llio = Llio2.WriteBuffer in
    let buf =
      Llio.serialize_with_length'
        (Llio.pair_to
           Llio.int_to
           serialize_request)
        (code,
         request)
    in

    Net_fd.write_all_lwt_bytes
      fd buf.Llio.buf 0 buf.Llio.pos
    >>= fun () ->

    with_response tag_name response_deserializer f
  in
  object(self)
    method private request' :
    type i o r. (i, o) request -> i -> (o -> r Lwt.t) -> r Lwt.t =
      fun command req f ->
      do_request
        (command_to_code (Wrap command))
        (deser_request_i command |> snd) req
        (Deser.from_buffer (deser_request_o session command))
        f

    method private request :
    type i o. (i, o) request -> i -> o Lwt.t =
      fun command req ->
      self # request' command req Lwt.return

    method do_unknown_operation =
      let code =
        (+)
          100
          (List.map
             (fun (code, _, _) -> code)
             command_map
           |> List.max
           |> Option.get_some)
      in
      Lwt.catch
        (fun () ->
         do_request
           code
           (fun buf () -> ()) ()
           (fun buf -> ())
           Lwt.return
         >>= fun () ->
         Lwt.fail_with "did not get an exception for unknown operation")
        (function
          | Error.Exn (Error.UnknownOperation, _) -> Lwt.return ()
          | exn -> Lwt.fail exn)

    method write_object_fs
        ~namespace ~object_name
        ~input_file
        ~allow_overwrite
        ?(checksum = None) () =
      self # request
        WriteObjectFs
        (namespace,
         object_name,
         input_file,
         allow_overwrite,
         checksum)

    method read_object_fs
      ~namespace ~object_name
      ~output_file
      ~consistent_read
      ~should_cache
      =
      self # request
        ReadObjectFs
        (namespace,
         object_name,
         output_file,
         consistent_read,
         should_cache)

    method read_object_slices ~namespace ~object_slices ~consistent_read =
      self # request ReadObjectsSlices (namespace, object_slices, consistent_read)

    method delete_object ~namespace ~object_name ~may_not_exist =
      self # request DeleteObject (namespace, object_name, may_not_exist)

    method apply_sequence ~namespace ~asserts ~updates ~write_barrier =
      self # request ApplySequence (namespace, write_barrier, asserts, updates)

    method multi_exists ~namespace ~object_names =
      self # request MultiExists (namespace, object_names)

    method read_objects : type o.
                               namespace : string ->
                               object_names : string list ->
                               consistent_read : bool ->
                               should_cache : bool ->
                               (int64 * (Nsm_model.Manifest.t * Bigstring_slice.t) option list -> o Lwt.t) ->
                               o Lwt.t
      =
      fun ~namespace ~object_names ~consistent_read ~should_cache f ->
      self # request'
           ReadObjects
           (namespace, object_names, consistent_read, should_cache)
           f

    method invalidate_cache ~namespace =
      self # request InvalidateCache namespace

    method statistics clear =
      self # request ProxyStatistics clear

    method get_version = self # request GetVersion ()

    method delete_namespace ~namespace =
      self # request DeleteNamespace namespace

    method list_object
             ~namespace ~first
             ~finc ~last ~max
             ~reverse
      = self # request ListObjects
             (namespace, RangeQueryArgs.({first; finc; last; max; reverse}))

    method create_namespace ~namespace ~preset_name =
      self # request CreateNamespace (namespace, preset_name)

    method list_namespaces ~first ~finc ~last
                          ~max ~reverse
      = self # request ListNamespaces
             RangeQueryArgs.{ first; finc; last; max; reverse; }

    method list_namespaces2 ~first ~finc ~last
                          ~max ~reverse
      = self # request ListNamespaces2
             RangeQueryArgs.{ first; finc; last; max; reverse; }

    method get_namespace_preset ~namespace =
      self # list_namespaces2
           ~first:namespace ~finc:true
           ~last:(Some (namespace, true))
           ~max:1 ~reverse:false >>= fun ((_, r), _) ->
      match r with
      | [] -> Lwt.return None
      | [ (n, preset) ] when n = namespace -> Lwt.return (Some preset)
      | _ -> assert false

    method osd_view = self # request OsdView ()

    method get_client_config = self # request GetClientConfig ()

    method osd_info = self # request OsdInfo ()

    method get_alba_id = self # request GetAlbaId ()

    method update_session kvs = self # request UpdateSession kvs
  end

let _prologue fd magic version =
  let buf = Buffer.create 8 in
  Llio.int32_to buf magic;
  Llio.int32_to buf version;
  Net_fd.write_all' fd (Buffer.contents buf)

let make_client ip port transport =
  Networking2.connect_with
    ~tls_config:None
    ip port transport
  >>= fun (nfd, closer) ->
  Lwt.catch
    (fun () ->
      _prologue nfd Protocol.magic Protocol.version >>= fun () ->
      let session = ProxySession.make () in
      let client = new proxy_client nfd session in
      Lwt.catch
        (fun () ->
          let manifest_ser = 2 in
          let kvs = [("manifest_ser", Some (serialize Llio.int8_to manifest_ser))]
          in
          client # update_session kvs >>= fun processed ->
          let () =
            List.iter
              (fun (k,v) ->
                match k with
                | "manifest_ser" ->
                   let manifest_ser = deserialize Llio.int8_from v in
                   ProxySession.set_manifest_ser session manifest_ser
                | _ -> ()
              ) processed
          in
          Lwt.return_unit
        )
        (let open Proxy_protocol.Protocol in
         function
         | Error.Exn (Error.UnknownOperation,_) -> Lwt.return_unit
         | exn -> Lwt.fail exn
        )
      >>= fun () ->
      Lwt.return (client, closer)
    )
    (fun exn ->
      closer () >>= fun () ->
      Lwt.fail exn)

let with_client ip port transport f =
  make_client ip port transport >>= fun (client, closer) ->
  Lwt.finalize
    (fun () -> f client)
    closer
