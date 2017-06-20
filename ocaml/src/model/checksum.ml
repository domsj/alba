(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude

module Checksum = struct
  module Algo = struct
    type t =
      | NO_CHECKSUM
      | SHA1
      | CRC32c
          [@@deriving show]

    let to_buffer buf = function
      | NO_CHECKSUM -> Llio.int8_to buf 1
      | SHA1 -> Llio.int8_to buf 2
      | CRC32c -> Llio.int8_to buf 3

    let from_buffer buf =
      match Llio.int8_from buf with
      | 1 -> NO_CHECKSUM
      | 2 -> SHA1
      | 3 -> CRC32c
      | k -> Prelude.raise_bad_tag "Checksum.Algo" k
  end

  type algo = Algo.t [@@deriving show]

  type t =
    | NoChecksum
    | Sha1 of HexString.t (* a string of size 20, actually *)
    | Crc32c of HexInt32.t [@@ deriving yojson]

  let show = function
    | NoChecksum -> "NoChecksum"
    | Sha1 x     -> Printf.sprintf "Sha1 %s" (HexString.show x)
    | Crc32c x   -> Printf.sprintf "Crc32c %s" (HexInt32.show x)


  let pp formatter t = Format.pp_print_string formatter (show t)

  let output buf = function
    | NoChecksum ->
      Llio.int8_to buf 1
    | Sha1 d ->
      Llio.int8_to buf 2;
      assert (String.length d = 20);
      Llio.string_to buf d
    | Crc32c d ->
      Llio.int8_to buf 3;
      Llio.int32_to buf d

  let input buf =
    match Llio.int8_from buf with
    | 1 -> NoChecksum
    | 2 ->
      let d = Llio.string_from buf in
      assert(String.length d = 20);
      Sha1 d
    | 3 ->
      let d = Llio.int32_from buf in
      Crc32c d
    | k -> Prelude.raise_bad_tag "checksum" k

  let deser = input, output
  let from_buffer, to_buffer = input, output

  let algo_of =
    let open Algo in
    function
    | NoChecksum -> NO_CHECKSUM
    | Sha1 _ -> SHA1
    | Crc32c _ -> CRC32c
end
