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

open Lwt.Infix
open Lwt_bytes2

let ignore_errors ?(logging=false) f =
  Lwt.catch
    f
    (function
      | Lwt.Canceled -> Lwt.fail Lwt.Canceled
      | exn ->
         if logging
         then Lwt_log.info ~exn "ignoring"
         else Lwt_log.debug ~exn "ignoring")

let with_timeout ~msg (timeout:float) f =
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout timeout f)
    (fun ex ->
     begin
       match ex with
       | Lwt_unix.Timeout -> Lwt_log.debug_f "Timeout(%.2f):%s" timeout msg
       | _ -> Lwt.return_unit
     end >>= fun () -> Lwt.fail ex
    )

let with_timeout_default ~msg timeout default f =
  Lwt.catch
    (fun () -> Lwt_unix.with_timeout timeout f)
    (function
     | Lwt_unix.Timeout ->
        Lwt_log.debug_f "Timeout(%.2f):%s" timeout msg
        >>= fun () ->
        Lwt.return default
     | exn -> Lwt.fail exn
    )


module CountDownLatch = struct
  type t = { mutable needed : int;
             mutable waiters : unit Lwt.u list; }

  let create ~count =
    assert (count >= 0);
    { needed = count; waiters = [] }

  let count_down t =
    if t.needed <> 0
    then
      t.needed <- t.needed - 1;
    if t.needed = 0
    then begin
      List.iter (fun lwtu -> Lwt.wakeup_later lwtu ()) t.waiters;
      t.waiters <- []
    end

  let finished t = t.needed = 0

  let current t = t.needed

  let await t =
    if finished t
    then Lwt.return ()
    else
      let lwtt, lwtu = Lwt.wait () in
      t.waiters <- lwtu :: t.waiters;
      lwtt
end

module FoldingCountDownLatch = struct
  type ('a, 'b) t = {
    latch : CountDownLatch.t;
    mutable acc : 'a;
    f : 'a -> 'b -> 'a; }

  let create ~count ~acc ~f =
    { latch = CountDownLatch.create ~count;
      acc; f; }

  let notify t b =
    if t.latch.CountDownLatch.needed <> 0
    then begin
      t.acc <- t.f t.acc b;
      CountDownLatch.count_down t.latch
    end

  let await t =
    let open Lwt in
    CountDownLatch.await t.latch >>= fun () ->
    Lwt.return t.acc
end

let sleep_approx ?(jitter=0.1) duration =
  let delta = Random.float (2. *. jitter) -. jitter in
  Lwt_unix.sleep ((1. +. delta) *. duration)

let rec run_forever msg f delay =
  Lwt.catch
    f
    (fun exn -> Lwt_log.debug ~exn msg) >>= fun () ->
  sleep_approx delay >>= fun () ->
  run_forever msg f delay

let lwt_unix_fd_to_fd
      (fd : Lwt_unix.file_descr) : int =
  Obj.magic (Obj.field (Obj.repr fd) 0)

let lwt_unix_fd_to_unix_fd
      (fd : Lwt_unix.file_descr) : Unix.file_descr =
  Obj.magic (Obj.field (Obj.repr fd) 0)

let unix_fd_to_fd (fd : Unix.file_descr) : int =
  Obj.magic fd

let with_fd filename ~flags ~perm f =
  Lwt_unix.openfile filename flags perm >>= fun fd ->
  Lwt.finalize
    (fun () -> f fd)
    (fun () -> Lwt_unix.close fd)

let fsync_dir dir =
  Lwt_unix.openfile dir [Unix.O_RDONLY] 0640 >>= fun dir_descr ->
  Lwt.finalize
    (fun () -> Lwt_unix.fsync dir_descr)
    (fun () -> Lwt_unix.close dir_descr)

let fsync_dir_of_file filename =
  fsync_dir (Filename.dirname filename)

let create_dir ?(sync = true) dir =
  Lwt_unix.mkdir dir 0o775 >>= fun () ->
  if sync
  then fsync_dir_of_file dir
  else Lwt.return ()

let unlink ?(may_not_exist=false) ~fsync_parent_dir file =
  Lwt.catch
    (fun () ->
     Lwt_unix.unlink file >>= fun () ->
     if fsync_parent_dir
     then fsync_dir_of_file file
     else Lwt.return ())
    (function
      | Unix.Unix_error(Unix.ENOENT, _, _) as exn ->
        if may_not_exist
        then Lwt.return_unit
        else Lwt.fail exn
      | exn ->
        Lwt.fail exn)

let rename ~fsync_parent_dir from dest =
  Lwt_unix.rename from dest >>= fun () ->
  if fsync_parent_dir
  then fsync_dir_of_file dest
  else Lwt.return ()

let stat filename =
  Lwt_log.debug_f "stat %S" filename >>= fun () ->
  Lwt_unix.stat filename

let exists filename =
  Lwt.catch
    (fun () -> stat filename >>= fun _ -> Lwt.return true)
    (function
      | Unix.Unix_error (Unix.ENOENT,_,_) -> Lwt.return false
      | e -> Lwt.fail e
    )

let _read_all read_to_target ifd offset length =
  let rec inner offset count = function
    | 0 ->
       begin
         if count < 20 || (length / count > 32768)
         then Lwt.return_unit
         else Lwt_log.info_f "reading from fd %i: %iB in %i steps" ifd length count
       end >>= fun () ->
       Lwt.return length
    | todo ->
       read_to_target offset todo >>= function
       | 0 -> Lwt.return (length - todo)
       | got -> inner (offset + got) (count + 1) (todo - got)
  in
  inner offset 0 length

let read_all_lwt_bytes fd target offset length =
  _read_all (Lwt_bytes.read_and_log fd target) (lwt_unix_fd_to_fd fd) offset length >>= fun result ->
   begin
   Lwt_log.ign_debug_f ">>> read_all_lwt_bytes from fd %i @ %nX size %i length %i offset %i end: %i -- %S"
                       (lwt_unix_fd_to_fd fd) (Lwt_bytes.raw_address target) (Lwt_bytes.length target)
                       length offset (offset + length)
                       (Printexc.get_callstack 5 |> Printexc.raw_backtrace_to_string);
   Lwt.return result;
   end

let expect_exact_length len length =
  if len = length
  then Lwt.return_unit
  else Lwt.fail End_of_file

let read_all_lwt_bytes_exact fd target offset length =
  read_all_lwt_bytes fd target offset length >>= expect_exact_length length

let read_all fd target offset length =
  begin
  Lwt_log.ign_debug_f ">>> read_all from fd %i length %i offset %i" (lwt_unix_fd_to_fd fd) length offset;
  _read_all (Lwt_unix.read fd target) (lwt_unix_fd_to_fd fd) offset length;
  end

let read_all_exact fd target offset length =
  read_all fd target offset length >>= expect_exact_length length


let _read_buffer_at_least read_to_target ~offset ~max_length ~min_length =
  let rec inner total_read =
    read_to_target
      (offset + total_read)
      (max_length - total_read)
    >>= function
    | 0 -> Lwt.fail End_of_file
    | read ->
       let total_read =  total_read + read in
       if total_read >= min_length
       then Lwt.return total_read
       else inner total_read
  in
  inner 0

let read_lwt_bytes_at_least fd target = _read_buffer_at_least (Lwt_bytes.read_and_log fd target)
let read_bytes_at_least fd target = _read_buffer_at_least (Lwt_unix.read fd target)


let _write_all write_from_source ifd offset length =
  let rec inner offset count = function
    | 0 ->
       if count < 20 || (length / count > 32768)
       then Lwt.return_unit
       else Lwt_log.info_f "writing to fd %i: %iB in %i steps" ifd length count
    | todo ->
       write_from_source offset todo >>= fun written ->
       inner (offset + written) (count + 1) (todo - written)
  in
  inner offset 0 length

let write_all_lwt_bytes fd source offset length =
  _write_all (Lwt_bytes.write fd source) (lwt_unix_fd_to_fd fd) offset length

let write_all fd source offset length =
  _write_all (Lwt_unix.write fd source) (lwt_unix_fd_to_fd fd) offset length

let write_all' fd source =
  write_all fd source 0 (Bytes.length source)

let llio_output_and_flush oc s =
  Llio.output_string oc s >>= fun () ->
  Lwt_io.flush oc


let make_fuse_thread () =
  let mvar = Lwt_mvar.create_empty () in
  let signals = [ (Sys.sigterm, "SIGTERM");
                  (Sys.sigint, "SIGINT"); ] in
  let signal_handler x =
    Lwt.ignore_result (Lwt_mvar.put mvar x)
  in
  List.iter
    (fun (signal, _) -> Lwt_unix.on_signal signal signal_handler |> ignore)
    signals;
  Lwt_mvar.take mvar >>= fun x ->
  let sig_name = List.assoc x signals in
  Lwt_log.warning_f "Got signal %s (%i), terminating..." sig_name x >>= fun () ->
  (* this statement flushes the log output stream (aka stdout) *)
  Lwt_io.printf "%!"

let get_files_of_directory dir =
  Lwt_stream.to_list (Lwt_unix.files_of_directory dir) >>= fun l ->
  let res =
    List.filter
      (fun fn -> not (List.mem fn [ Filename.parent_dir_name;
                                    Filename.current_dir_name; ]))
      l
  in
  Lwt.return res

let read_file file =
  Lwt_io.file_length file >>= fun len ->
  let len' = Int64.to_int len in
  let buf = Bytes.create len' in
  with_fd
    file
    ~flags:Lwt_unix.([O_RDONLY;])
    ~perm:0600
    (fun fd ->
       read_all fd buf 0 len' >>= fun read ->
       assert (read = len');
       Lwt.return ()) >>= fun () ->
  Lwt.return buf

let copy_using
      reader writer
      size buffer
  =
  let buffer_size = Lwt_bytes.length buffer in
  let rec loop todo =
    if todo = 0
    then Lwt.return_unit
    else
      begin
        let step =
          if todo <= buffer_size
          then todo
          else buffer_size
        in
        reader buffer 0 step >>= fun bytes_read ->
        writer buffer 0 bytes_read >>= fun () ->
        loop (todo - bytes_read)
      end
  in
  loop size

let copy_between_fds fd_in fd_out size buffer =
  let reader = Lwt_bytes.read fd_in in
  let writer = write_all_lwt_bytes fd_out in
  copy_using reader writer size buffer

let join_threads_ignore_errors ts =
  Lwt.join
    (List.map
       (fun t ->
         Lwt.catch
           (fun () -> t >>= fun _ -> Lwt.return_unit)
           (fun exn -> Lwt.return_unit))
       ts)

let first_n ~count ~slack f items ~test =
  let t0 = Unix.gettimeofday() in
  let success = CountDownLatch.create ~count in
  let n_items = List.length items in
  let failures = CountDownLatch.create ~count:(n_items - count + 1) in

  let log_state index =
    let open CountDownLatch in
    Lwt_log.debug_f
      "%i finished (needed=%i, distance to failure=%i)%!"
      index
      success.needed
      failures.needed
  in

  let ts = List.mapi
             (fun index item ->
               Lwt.catch
                 (fun () ->
                   f item >>= fun r ->
                   if test r
                   then CountDownLatch.count_down success
                   else CountDownLatch.count_down failures;
                   log_state index >>= fun () ->
                   Lwt.return r)
                 (fun exn ->
                   CountDownLatch.count_down failures;
                   log_state index >>= fun () ->
                   Lwt.fail exn))
             items
  in

  Lwt.choose [CountDownLatch.await success;
              CountDownLatch.await failures;
             ]
  >>= fun () ->
  let t1 = Unix.gettimeofday() in
  let so_far = t1 -. t0 in
  let limit = so_far *. slack in
  Lwt_log.debug_f "waiting for another %f * %f =%f" so_far slack limit
  >>= fun () ->
  Lwt.choose
    [ begin
        Lwt_unix.sleep limit >>= fun () ->
        Lwt_log.debug "limit reached"
      end;
      join_threads_ignore_errors ts;
    ]
  >>= fun () ->
  Lwt.return (CountDownLatch.finished success, ts)
