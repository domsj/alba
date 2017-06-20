(*
  Copyright (C) iNuron - info@openvstorage.com
  This file is part of Open vStorage. For license information, see <LICENSE.txt>
*)

open! Prelude
open Lwt.Infix

let maintenance_for_all_x
      task_name
      list_x
      maintenance_f
      get_x_id
      show_x
      is_master
  =
  let x_threads = Hashtbl.create 4 in

  let sync_x_threads () =
    (if is_master ()
     then list_x()
     else Lwt.return (0,[])) >>= fun (_,xs) ->
    List.iter
      (fun x ->
         let x_id = get_x_id x in
         let t =
           if Hashtbl.mem x_threads x_id
           then Lwt.return ()
           else
             begin
               Hashtbl.add x_threads x_id ();
               Lwt.finalize
                 (fun () ->
                  Lwt.catch
                    (fun () ->
                     Lwt_log.debug_f
                       "Starting %s for %s"
                       task_name (show_x x) >>= fun () ->
                     maintenance_f x)
                    (fun exn ->
                     Lwt_log.debug_f
                       ~exn
                       "Thread %s for %s stopped due to an exception"
                       task_name (show_x x)))
                 (fun () ->
                  Hashtbl.remove x_threads x_id;
                  Lwt.return ())
             end
         in
         Lwt.ignore_result t)
      xs;

    Lwt.return ()
  in
  Lwt_extra2.run_forever
    (Printf.sprintf "Got unexpected exception in main %s thread" task_name)
    sync_x_threads
    60.
