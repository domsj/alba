(*
 * This file is part of Baardskeerder.
 *
 * Copyright (C) 2011 Incubaid BVBA
 *
 * Baardskeerder is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Baardskeerder is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Baardskeerder.  If not, see <http://www.gnu.org/licenses/>.
 *)

open! Prelude

(* we (OVS) only took what we needed and adapted the signatures a bit *)

(* posix_fadvise *)
type posix_fadv = POSIX_FADV_NORMAL
                  | POSIX_FADV_SEQUENTIAL
                  | POSIX_FADV_RANDOM
                  | POSIX_FADV_NOREUSE
                  | POSIX_FADV_WILLNEED
                  | POSIX_FADV_DONTNEED

external posix_fadvise: Unix.file_descr -> int -> int -> posix_fadv -> unit
  = "_bs_posix_fadvise"

external fallocate: Unix.file_descr -> int -> int -> int -> unit
  = "_bs_posix_fallocate"
      
let lwt_posix_fadvise fd pos len fadv =
  let ufd = Lwt_unix.unix_file_descr fd in
  Lwt_preemptive.detach
    (fun () -> posix_fadvise ufd 0 len fadv) ()

let lwt_fallocate fd mode offset len =
  let ufd = Lwt_unix.unix_file_descr fd in
  Lwt_preemptive.detach
    (fun () -> fallocate ufd mode offset len) ()
