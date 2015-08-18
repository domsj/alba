(*
Copyright 2015 Open vStorage NV

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

open Prelude
open Slice
open Nsm_model
open Encryption
open Gcrypt
open Lwt.Infix

let get_iv algo key ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id =
  (*
     deterministic iv for fragment encryption
     this way we get security without needing to store the iv in the manifest / recovery info

     concatenate object_id chunk_id fragment_id |>
     encrypt AES key CBC |>
     take last block
 *)
  let fragment_id =
    if ignore_fragment_id
    then 0
    else fragment_id
  in
  let open Encryption in
  match algo with
  | AES (CBC, L256) ->
    let s =
      serialize
        (Llio.tuple3_to
           Llio.string_to
           Llio.int_to
           Llio.int_to)
        (object_id, chunk_id, fragment_id)
    in

    let block_len = block_length algo in
    let bs = Padding.pad (Lwt_bytes.of_string s) block_len in

    Cipher.with_t_lwt
      key Cipher.AES256 Cipher.CBC []
      (fun cipher -> Cipher.encrypt cipher bs) >>= fun () ->

    let res = Str.last_chars (Lwt_bytes.to_string bs) block_len in
    Lwt.return res

let maybe_encrypt
    encryption
    ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id
    plain =
  let open Encryption in
  match encryption with
  | NoEncryption ->
    Lwt.return plain
  | AlgoWithKey (AES (CBC, L256) as algo, key) ->
    verify_key_length algo key;
    let block_len = block_length algo in
    let bs = Padding.pad plain block_len in
    get_iv algo key ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id >>= fun iv ->
    Cipher.with_t_lwt
      key Cipher.AES256 Cipher.CBC []
      (fun cipher -> Cipher.encrypt ~iv cipher bs) >>= fun () ->
    Lwt.return bs

let maybe_decrypt
    encryption
    ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id
    data =
  let open Encryption in
  match encryption with
  | NoEncryption ->
    Lwt.return data
  | AlgoWithKey (algo, key) ->
    begin match algo with
      | AES (CBC, L256) ->
        Encryption.verify_key_length algo key;
        get_iv algo key ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id >>= fun iv ->
        Cipher.with_t_lwt
          key Cipher.AES256 Cipher.CBC []
          (fun cipher -> Cipher.decrypt ~iv cipher data) >>= fun () ->
        Lwt.return (Padding.unpad data)
    end

let maybe_compress compression fragment_data =
  let open Lwt.Infix in
  Compressors.compress compression fragment_data >>= fun r ->
  Lwt_log.debug_f
    "compression: %s (%i => %i)"
    ([%show: Compression.t] compression)
    (Lwt_bytes.length fragment_data)
    (Lwt_bytes.length r) >>= fun () ->
  Lwt.return r

let maybe_decompress compression compressed =
  let open Lwt.Infix in
  Compressors.decompress compression compressed >>= fun r ->
  Lwt_log.debug_f
     "decompression: %s (%i => %i)"
     ([%show: Compression.t] compression)
     (Lwt_bytes.length compressed)
     (Lwt_bytes.length r) >>= fun () ->
  Lwt.return r


let verify fragment_data checksum =
  let algo = Checksum.algo_of checksum in
  let hash = Hashes.make_hash algo in
  hash # update_lwt_bytes_detached
    fragment_data
    0
    (Lwt_bytes.length fragment_data) >>= fun () ->
  let checksum2 = hash # final () in
  Lwt.return (checksum2 = checksum)

let verify' fragment_data checksum =
  let algo = Checksum.algo_of checksum in
  let hash = Hashes.make_hash algo in
  let open Slice in
  hash # update_substring
    fragment_data.buf
    fragment_data.offset
    fragment_data.length;
  let checksum2 = hash # final () in
  Lwt.return (checksum2 = checksum)

let pack_fragment
    fragment
    ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id
    compression
    encryption
    checksum_algo
  =
  let with_timing_lwt = Alba_statistics.Statistics.with_timing_lwt in
  with_timing_lwt
    (fun () ->
       maybe_compress compression fragment
       >>= fun compressed ->
       maybe_encrypt
         ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id
         encryption
         compressed)
  >>= fun (t_compress_encrypt, final_data) ->

  with_timing_lwt
    (fun () ->
       let hash = Hashes.make_hash checksum_algo in
       hash # update_lwt_bytes_detached final_data 0 (Lwt_bytes.length final_data) >>= fun () ->
       Lwt.return (hash # final ()))
  >>= fun (t_hash, checksum) ->

  Lwt.return (final_data, t_compress_encrypt, t_hash, checksum)

let chunk_to_data_fragments ~chunk ~chunk_size ~k =
  let fragment_size = chunk_size / k in
  let data_fragments =
    let rec inner acc = function
      | 0 ->
        acc
      | n ->
        let fragment =
          let pos = (n-1) * fragment_size in
          Bigarray.Array1.sub chunk pos fragment_size
        in
        inner (fragment :: acc) (n - 1) in
    inner [] k in
  data_fragments

(* this should be at least sizeof(long) according to the jerasure documentation *)
let fragment_multiple = 16

let chunk_to_fragments_ec
    ~chunk ~chunk_size
    ~k ~m ~w' =

  let fragment_size = chunk_size / k in

  Lwt_log.debug_f
    "chunk_to_fragments: chunk_size = %i ; fragment_size=%i"
    chunk_size fragment_size >>= fun () ->

  assert (chunk_size mod (fragment_multiple * k) = 0);

  let data_fragments =
    chunk_to_data_fragments
      ~chunk
      ~chunk_size
      ~k
  in

  let coding_fragments =
    let rec inner acc = function
      | 0 -> acc
      | n ->
        let fragment =
          Bigarray.Array1.create
            Bigarray.Char
            Bigarray.C_layout
            fragment_size in
        inner (fragment :: acc) (n - 1) in
    inner [] m
  in

  Erasure.encode
    ~k ~m ~w:w'
    data_fragments
    coding_fragments
    fragment_size >>= fun () ->

  let all_data = List.append data_fragments coding_fragments in

  let data_with_fragment_id =
    List.mapi
      (fun i data -> i, data)
      all_data
  in

  Lwt.return data_with_fragment_id

let chunk_to_packed_fragments
    ~object_id ~chunk_id
    ~chunk ~chunk_size
    ~k ~m ~w'
    ~compression ~encryption ~fragment_checksum_algo
  =
  if k = 1
  then
    begin
      let fragment = chunk in
      pack_fragment
        fragment
        ~object_id ~chunk_id ~fragment_id:0 ~ignore_fragment_id:true
        compression encryption fragment_checksum_algo
      >>= fun (packed, f1, f2, cs) ->
      let packed' = Slice.of_bigstring packed in
      Core_kernel.Bigstring.unsafe_destroy packed;

      let rec build_result acc = function
        | 0 -> acc
        | n ->
          let fragment_id = n - 1 in
          let acc' = (fragment_id, fragment, (packed', f1, f2, cs)) :: acc in
          build_result
            acc'
            (n-1)
      in
      Lwt.return (build_result [] (k+m))
    end
  else
    begin
      chunk_to_fragments_ec
        ~chunk ~chunk_size
        ~k ~m ~w' >>=
      Lwt_list.map_p
        (fun (fragment_id, fragment) ->
           pack_fragment
             fragment
             ~object_id ~chunk_id ~fragment_id ~ignore_fragment_id:false
             compression encryption fragment_checksum_algo
           >>= fun (packed, f1, f2, cs) ->
           let packed' = Slice.of_bigstring packed in
           Core_kernel.Bigstring.unsafe_destroy packed;

           Lwt.return (fragment_id, fragment, (packed', f1, f2, cs)))
    end
