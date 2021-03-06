(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Lwt.Infix
open Slice
open Asd_protocol
open Protocol
open Range_query_args

class _inner_client (fd:Net_fd.t) id =
  let () = Net_fd.uncork fd in

  let buffer =
    let msg = Printf.sprintf "asd_client %s line:%i" id __LINE__ in
    Lwt_bytes.create ~msg (4+5+4096) |> ref
  in
  let buf_extra_offset = ref 0 in
  let buf_extra_length = ref 0 in

  let read_from_extra_bytes_or_fd_exact buf offset length =
    let offset, length =
      if !buf_extra_length > 0
      then
        begin
          let bytes_to_blit = min length !buf_extra_length in
          Lwt_bytes.blit !buffer !buf_extra_offset buf offset bytes_to_blit;
          buf_extra_offset := !buf_extra_offset + bytes_to_blit;
          buf_extra_length := !buf_extra_length - bytes_to_blit;
          offset + bytes_to_blit, length - bytes_to_blit
        end
      else
        offset, length
    in
    Net_fd.read_all_lwt_bytes_exact fd buf offset length
  in

  let with_response deserializer f =
    Net_fd.with_message_buffer_from
      fd buffer None
      ~max_buffer_size:16500
      (fun ~buffer ~offset ~message_length ~extra_bytes ->

        buf_extra_offset := offset + message_length;
        buf_extra_length := extra_bytes;

        let module L = Llio2.ReadBuffer in
        let res_buf = L.make_buffer buffer ~offset ~length:message_length in

        match L.int_from res_buf with
        | 0 ->
           f (deserializer res_buf)
        | err ->
           let open Error in
           let err' = deserialize' err res_buf in
           Lwt_log.debug_f "Exception in asd_client %s: %s" id (show err') >>= fun () ->
           lwt_fail err'
      ) >>= fun r ->
    assert (!buf_extra_length = 0);
    Lwt.return r
  in
  let do_request
        code
        serialize_request request
        deserialize_response
        f =
    let description = code_to_description code in
    Lwt_log.debug_f
      "asd_client %s: %s"
      id description >>= fun () ->
    with_timing_lwt
      (fun () ->
        let module Llio = Llio2.WriteBuffer in

        let buffer' = Llio.({ buf = !buffer; pos = 0; }) in
        let buf =
          Llio.serialize_with_length'
            ~buf:buffer'
            (Llio.pair_to
               Llio.int32_to
               serialize_request)
            (code,
             request)
        in

        (* serialize above may have created a new buf and unsafe destroyed the previous one *)
        buffer := buffer'.Llio.buf;

        Net_fd.write_all_lwt_bytes fd buf.Llio.buf 0 buf.Llio.pos
        >>= fun () ->
        with_response deserialize_response f)
    >>= fun (t, r) ->
    Lwt_log.debug_f "asd_client %s: %s took %f" id description t >>= fun () ->
    Lwt.return r
  in
  object(self)
    method private query :
    type req res a.
         (req, res) query -> req ->
         (res -> a Lwt.t) -> a Lwt.t =
      fun command req f ->
      do_request
        (command_to_code (Wrap_query command))
        (query_request_serializer command) req
        (query_response_deserializer command)
        f

    method private update :
    type req res a.
         (req, res) update -> req ->
         (res -> a Lwt.t) -> a Lwt.t =
      fun command req f ->
      do_request
        (command_to_code (Wrap_update command))
        (update_request_serializer command) req
        (update_response_deserializer command)
        f

    method do_unknown_operation =
      let code =
        Int32.add
          100l
          (List.map
             (fun (_, code, _) -> code)
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
           Lwt.return >>= fun () ->
         Lwt.fail_with "did not get an exception for unknown operation")
        (function
          | Error.Exn Error.Unknown_operation ->
             Lwt.return ()
          | exn ->
             Lwt.fail exn)

    val mutable supports_multiget2 = None
    method multi_get ~prio keys =
      let old_multiget () =
        self # query
             MultiGet
             (keys, prio)
             (fun res ->
              List.map
                (Option.map
                   (fun (bss, cs) ->
                    Bigstring_slice.extract_to_bigstring bss, cs))
                res
             |> Lwt.return)
      in
      match supports_multiget2 with
      | None ->
         (* try multiget2, if it succeeds the asd supports it *)
         Lwt.catch
           (fun () ->
            self # multi_get2 ~prio keys >>= fun res ->
            supports_multiget2 <- Some true;
            Lwt.return res)
           (function
             | Error.Exn Error.Unknown_operation ->
                supports_multiget2 <- Some false;
                old_multiget ()
             | exn ->
                Lwt.fail exn)
      | Some true ->
         self # multi_get2 ~prio keys
      | Some false ->
         old_multiget ()

    method multi_get2 ~prio keys =
      self # query MultiGet2 (keys, prio)
           (Lwt_list.map_s
              (let open Value in
               function
               | None -> Lwt.return_none
               | Some (blob, cs) ->
                  match blob with
                  | Direct s ->
                     let bs = Slice.to_bigstring ~msg:"Direct" s in
                     Lwt.return (Some (bs, cs))
                  | Later size ->
                     let bs = Lwt_bytes.create ~msg:"Later" size in
                     Lwt.catch
                       (fun () ->
                        read_from_extra_bytes_or_fd_exact bs 0 size >>= fun () ->
                        Lwt.return (Some (bs, cs)))
                       (fun exn ->
                        Lwt_bytes.unsafe_destroy ~msg:"asd_client multi_get2" bs;
                        Lwt.fail exn)))

    method multi_get_string ~prio keys =
      self # multi_get ~prio (List.map Slice.wrap_string keys) >>= fun res ->
      Lwt.return
        (List.map
           (Option.map
              (fun (buf, cs) ->
                let r = Lwt_bytes.to_string buf in
                Lwt_bytes.unsafe_destroy ~msg:"multi_get_string" buf;
                r, cs
              )
           )
           res)

    method multi_exists ~prio keys =
      self # query MultiExists (keys, prio) Lwt.return

    method raw_partial_get ~prio key slices =
      self # query
           PartialGet
           (key,
            List.map
              (fun (offset, length, _, _) ->
               offset, length)
              slices,
            prio)
           (function
             | false ->
                Lwt.return_false
             | true ->
                (* TODO could optimize the number of syscalls using readv *)
                Lwt_list.iter_s
                  (fun (_, length, dest, destoff) ->
                   read_from_extra_bytes_or_fd_exact dest destoff length)
                  slices >>= fun () ->
                Lwt.return_true)

    val mutable supports_partial_get = None
    method partial_get ~prio key slices =
      let map_output = function
        | true -> Lwt.return Osd.Success
        | false -> Lwt.return Osd.NotFound
      in
      match supports_partial_get with
      | Some false -> Lwt.return Osd.Unsupported
      | Some true ->
         self # raw_partial_get ~prio key slices
         >>= map_output
      | None ->
         Lwt.catch
           (fun () ->
            self # raw_partial_get ~prio key slices >>= fun r ->
            supports_partial_get <- Some true;
            map_output r)
           (function
             | Error.Exn Error.Unknown_operation ->
                supports_partial_get <- Some false;
                Lwt.return Osd.Unsupported
             | exn ->
                Lwt.fail exn)

    method get ~prio key =
      self # multi_get ~prio [ key ] >>= fun res ->
      List.hd_exn res |>
      Lwt.return

    method get_string ~prio key =
      self # multi_get_string ~prio [ key ] >>= fun res ->
      List.hd_exn res |>
      Lwt.return

    method set ~prio key value assertable ?(cs = Checksum.Checksum.NoChecksum) () =
      let u = Update.set key value cs assertable in
      self # apply_sequence ~prio [] [u] >>= fun _ ->
      Lwt.return ()

    method set_string ~prio ?(cs = Checksum.Checksum.NoChecksum)
             key value assertable
      =
      let u = Update.set_string key value cs assertable in
      self # apply_sequence ~prio [] [u] >>= fun _ ->
      Lwt.return ()

    method delete ~prio key =
      self # apply_sequence ~prio [] [ Update.delete key ] >>= fun _ ->
      Lwt.return ()

    method delete_string ~prio key =
      self # apply_sequence ~prio [] [ Update.delete_string key ] >>= fun _ ->
      Lwt.return ()

    method range ~prio ~first ~finc ~last ~reverse ~max =
      self # query
        Range
        (RangeQueryArgs.({ first; finc; last; reverse; max }), prio)
        Lwt.return

    method range_all ~prio ?(max = -1) () =
      list_all_x
        ~first:(Slice.wrap_string "")
        Std.id
        (self # range ~prio ~last:None ~max ~reverse:false)

    method range_string ~prio ~first ~finc ~last ~reverse ~max =
      self # range
        ~prio
        ~first:(Slice.wrap_string first) ~finc
        ~last:(Option.map (fun (l, linc) -> Slice.wrap_string l, linc) last)
        ~max ~reverse >>= fun ((cnt, keys), has_more) ->
      Lwt.return ((cnt, List.map Slice.get_string_unsafe keys), has_more)

    method range_entries ~prio ~first ~finc ~last ~reverse ~max =
      self # query
        RangeEntries
        (RangeQueryArgs.({ first; finc; last; reverse; max; }), prio)
        (fun ((cnt, items), has_more) ->
         let items' =
           List.map
             (fun (k, v, cs) -> k, Bigstring_slice.extract_to_bigstring v, cs)
             items
         in
         Lwt.return ((cnt, items'), has_more))

    method apply_sequence ~prio asserts updates =
      self # update Apply (asserts, updates, prio) Lwt.return

    method statistics clear =
      self # query Statistics clear Lwt.return

    method set_full full =
      self # update SetFull full Lwt.return

    method set_slowness slowness =
      self # update Slowness slowness Lwt.return

    method get_version () =
      self # query GetVersion () Lwt.return

    method get_disk_usage () =
      self # query GetDiskUsage () Lwt.return

    method capabilities () =
      self # query Capabilities () Lwt.return

    method range_validate ~prio ~first ~finc ~last ~reverse ~max ~verify_checksum ~show_all =
      self # query
           RangeValidate
           (RangeQueryArgs.({first;finc;last;reverse;max}), verify_checksum, show_all, prio)
           Lwt.return

    method dispose () = Lwt_bytes.unsafe_destroy ~msg:"asd_client _inner_client dispose" !buffer
  end

exception BadLongId of string * string

let conn_info_from ~tls_config (conn_info':Nsm_model.OsdInfo.conn_info)  =
  let ips,port, use_tls , use_rdma = conn_info' in
  let tls_config =
    match use_tls,tls_config with
    | false, None   -> None
    | false, Some _ -> None
    | true, None    -> failwith "want tls, but no tls_config is None !?"
    | true, Some _  -> tls_config
  in
  let transport = if use_rdma then Net_fd.RDMA else Net_fd.TCP in
  Networking2.make_conn_info ips port ~transport tls_config

let make_prologue magic version lido =
  let buf = Buffer.create 16 in
  Buffer.add_string buf magic;
  Llio.int32_to     buf version;
  Llio.string_option_to buf lido;
  Buffer.contents buf

let _prologue_response fd lido =
  Llio2.NetFdReader.int32_from fd >>=
    function
    | 0l ->
       begin
         Llio2.NetFdReader.string_from fd >>= fun asd_id' ->
         match lido with
         | Some asd_id when asd_id <> asd_id' ->
            Lwt.fail (BadLongId (asd_id, asd_id'))
         | _ -> Lwt.return asd_id'
       end
    | err -> Error.from_stream (Int32.to_int err) fd

class client (version:Alba_version.t) fd id =
object(self)
  inherit _inner_client fd id
  method version () = version
end

let make_client ~conn_info (lido:string option)  =
  Networking2.first_connection ~conn_info
  >>= fun (nfd, closer) ->
  Lwt.catch
    (let inner () =
       let open Asd_protocol in
       let prologue_bytes = make_prologue _MAGIC _VERSION lido in
       Net_fd.write_all' nfd prologue_bytes >>= fun () ->
       _prologue_response nfd lido >>= fun long_id ->
       let inner = new _inner_client nfd long_id in
       inner # get_version () >>= fun version ->
       let client = new client version nfd long_id in
       let closer' () =
         let () = client # dispose () in
         closer()
       in
       Lwt.return (client, closer')
     in
     fun () -> Lwt_extra2.with_timeout_no_cancel 5.0 inner
    )
    (fun exn ->
      closer () >>= fun () ->
     Lwt.fail exn)

let with_client ~conn_info (lido:string option) f =
  make_client ~conn_info lido >>= fun (client, closer) ->
  Lwt.finalize
    (fun () -> f client)
    closer

class asd_osd (asd_id : string) (asd : client) =
object(self :# Osd.key_value_osd)

  method kvs =
    object(self)
      method get_option prio (k:key) =
        asd # get ~prio k >>= function
        | None -> Lwt.return_none
        | Some (v,c) -> Lwt.return (Some v)

      method get_exn prio (k:key) =
        self # get_option prio k >>= function
        | None -> Lwt.fail_with (Printf.sprintf
                                   "Could not find key %s on asd %S"
                                   (Slice.get_string_unsafe k) asd_id)
        | Some v -> Lwt.return v

      method multi_get prio keys =
        asd # multi_get ~prio keys >>= fun vcos ->
        Lwt.return
          (List.map
             (Option.map fst)
             vcos)

      method multi_exists prio keys = asd # multi_exists ~prio keys

      method partial_get prio key slices = asd # partial_get ~prio key slices

      method range prio = asd # range ~prio

      method range_entries prio = asd # range_entries ~prio

      method apply_sequence prio asserts (upds: Update.t list) =
        Lwt.catch
          (fun () ->
            asd # apply_sequence ~prio asserts upds
            >>= fun (fnrs : (key * string) list) ->
            Lwt.return (Ok fnrs)
          )
          (function
            | Error.Exn e ->
               Lwt.return (Error e)
            | exn -> Lwt.fail exn)
    end

  method set_full full = asd # set_full full
  method set_slowness slowness = asd # set_slowness slowness
  method get_version = asd # get_version ()
  method version () = asd # version ()
  method get_long_id = asd_id
  method get_disk_usage = asd # get_disk_usage ()
  method capabilities = asd # capabilities ()
end
