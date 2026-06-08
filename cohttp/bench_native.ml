(* cohttp running natively on the Lwt_effects scheduler (epoll backend), via the
   Le_cohttp IO backend and the generic Cohttp request/response codecs. Compared
   with cohttp-lwt-unix (Lwt_main) and cohttp-eio. *)

let conns = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 50
let reqs = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 200
let total = conns * reqs
let body = "hello"

let report name dt =
  Printf.printf "  %-34s %8.3f s  %10.0f req/s\n%!" name dt
    (float_of_int total /. dt)

let loopback = Unix.inet_addr_loopback

let make_listener () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (loopback, 0));
  Unix.listen s 1024;
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | Unix.ADDR_UNIX _ -> failwith "inet"
  in
  (s, port)

(* ------------------------------------------------------------------ *)
(* cohttp natively on Lwt_effects (epoll)                             *)
(* ------------------------------------------------------------------ *)

module C =
  Le_cohttp.Make (struct
    let read = Lwt_effects.Io.read_m
    let write = Lwt_effects.Io.write_m
  end)

let bench_native () =
  let open Lwt_effects in
  let open Lwt_effects.Compat in
  let ls, port = make_listener () in
  Unix.set_nonblock ls;
  let resp =
    let headers =
      Cohttp.Header.add_transfer_encoding (Cohttp.Header.init ())
        (Cohttp.Transfer.Fixed (Int64.of_int (String.length body)))
    in
    let headers = Cohttp.Header.add headers "connection" "keep-alive" in
    Cohttp.Response.make ~status:`OK ~headers ()
  in
  let serve fd =
    let ic = C.IO.make_ic fd and oc = C.IO.make_oc fd in
    let rec loop () =
      C.Request.read ic >>= function
      | `Eof | `Invalid _ -> return_unit
      | `Ok _req ->
        C.Response.write ~flush:false
          (fun w -> C.Response.write_body w body)
          resp oc
        >>= fun () -> C.IO.flush oc >>= fun () -> loop ()
    in
    loop () >>= fun () ->
    Unix.close fd;
    return_unit
  in
  let req =
    let headers = Cohttp.Header.init () in
    let headers = Cohttp.Header.add headers "connection" "keep-alive" in
    let headers = Cohttp.Header.add headers "content-length" "0" in
    Cohttp.Request.make ~meth:`GET ~headers
      (Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port ~path:"/" ())
  in
  let client () =
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.set_nonblock s;
    Io.connect_m s (Unix.ADDR_INET (loopback, port)) >>= fun () ->
    let ic = C.IO.make_ic s and oc = C.IO.make_oc s in
    let rec loop i =
      if i = 0 then (Unix.close s; return_unit)
      else begin
        C.Request.write ~flush:false (fun _ -> return_unit) req oc >>= fun () ->
        C.IO.flush oc >>= fun () ->
        C.Response.read ic >>= function
        | `Eof | `Invalid _ -> fail (Failure "bad response")
        | `Ok r ->
          let reader = C.Response.make_body_reader r ic in
          let rec drain () =
            C.Response.read_body_chunk reader >>= function
            | Cohttp.Transfer.Done -> return_unit
            | Cohttp.Transfer.Final_chunk _ -> return_unit
            | Cohttp.Transfer.Chunk _ -> drain ()
          in
          drain () >>= fun () -> loop (i - 1)
      end
    in
    loop reqs
  in
  let rec accept_loop n acc =
    if n = 0 then return acc
    else
      Io.accept_m ls >>= fun (c, _) ->
      Unix.set_nonblock c;
      accept_loop (n - 1) (serve c :: acc)
  in
  let server () = accept_loop conns [] >>= fun hs -> join hs in
  let t0 = Unix.gettimeofday () in
  run (fun () ->
    both (server ()) (join (List.init conns (fun _ -> client ())))
    >>= fun _ -> return_unit);
  Unix.close ls;
  Unix.gettimeofday () -. t0

(* ------------------------------------------------------------------ *)
(* cohttp natively on Lwt_effects over io_uring                       *)
(* ------------------------------------------------------------------ *)

(* Bytes I/O over the ring (the ring is Cstruct-based, so a small copy). *)
module CU =
  Le_cohttp.Make (struct
    let read fd buf off len =
      let cs = Cstruct.create len in
      Lwt_effects.Compat.bind (Lwt_effects_uring.Io.read_m fd cs) (fun n ->
        Cstruct.blit_to_bytes cs 0 buf off n;
        Lwt_effects.return n)

    let write fd buf off len =
      Lwt_effects_uring.Io.write_m fd (Cstruct.of_bytes (Bytes.sub buf off len))
  end)

let bench_native_uring () =
  let open Lwt_effects in
  let open Lwt_effects.Compat in
  let module U = Lwt_effects_uring in
  let ls, port = make_listener () in
  Unix.set_nonblock ls;
  let resp =
    let headers =
      Cohttp.Header.add_transfer_encoding (Cohttp.Header.init ())
        (Cohttp.Transfer.Fixed (Int64.of_int (String.length body)))
    in
    let headers = Cohttp.Header.add headers "connection" "keep-alive" in
    Cohttp.Response.make ~status:`OK ~headers ()
  in
  let serve fd =
    let ic = CU.IO.make_ic fd and oc = CU.IO.make_oc fd in
    let rec loop () =
      CU.Request.read ic >>= function
      | `Eof | `Invalid _ -> return_unit
      | `Ok _req ->
        CU.Response.write ~flush:false
          (fun w -> CU.Response.write_body w body)
          resp oc
        >>= fun () -> CU.IO.flush oc >>= fun () -> loop ()
    in
    loop () >>= fun () ->
    Unix.close fd;
    return_unit
  in
  let req =
    let headers = Cohttp.Header.init () in
    let headers = Cohttp.Header.add headers "connection" "keep-alive" in
    let headers = Cohttp.Header.add headers "content-length" "0" in
    Cohttp.Request.make ~meth:`GET ~headers
      (Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port ~path:"/" ())
  in
  let client () =
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.set_nonblock s;
    U.Io.connect_m s (Unix.ADDR_INET (loopback, port)) >>= fun () ->
    Unix.clear_nonblock s;
    let ic = CU.IO.make_ic s and oc = CU.IO.make_oc s in
    let rec loop i =
      if i = 0 then (Unix.close s; return_unit)
      else begin
        CU.Request.write ~flush:false (fun _ -> return_unit) req oc >>= fun () ->
        CU.IO.flush oc >>= fun () ->
        CU.Response.read ic >>= function
        | `Eof | `Invalid _ -> fail (Failure "bad response")
        | `Ok r ->
          let reader = CU.Response.make_body_reader r ic in
          let rec drain () =
            CU.Response.read_body_chunk reader >>= function
            | Cohttp.Transfer.Done -> return_unit
            | Cohttp.Transfer.Final_chunk _ -> return_unit
            | Cohttp.Transfer.Chunk _ -> drain ()
          in
          drain () >>= fun () -> loop (i - 1)
      end
    in
    loop reqs
  in
  let rec accept_loop n acc =
    if n = 0 then return acc
    else U.Io.accept_m ls >>= fun (c, _) -> accept_loop (n - 1) (serve c :: acc)
  in
  let server () = accept_loop conns [] >>= fun hs -> join hs in
  let t0 = Unix.gettimeofday () in
  U.run (fun () ->
    both (server ()) (join (List.init conns (fun _ -> client ())))
    >>= fun _ -> return_unit);
  Unix.close ls;
  Unix.gettimeofday () -. t0

(* ------------------------------------------------------------------ *)
(* New-connection-per-request variant (epoll), to compare fairly with  *)
(* the cohttp-lwt / cohttp-eio Client.get benches (which reconnect).    *)
(* ------------------------------------------------------------------ *)

let bench_native_newconn () =
  let open Lwt_effects in
  let open Lwt_effects.Compat in
  let ls, port = make_listener () in
  Unix.set_nonblock ls;
  let resp =
    let headers =
      Cohttp.Header.add_transfer_encoding (Cohttp.Header.init ())
        (Cohttp.Transfer.Fixed (Int64.of_int (String.length body)))
    in
    Cohttp.Response.make ~status:`OK ~headers ()
  in
  let handle fd =
    let ic = C.IO.make_ic fd and oc = C.IO.make_oc fd in
    C.Request.read ic >>= function
    | `Eof | `Invalid _ -> Unix.close fd; return_unit
    | `Ok _ ->
      C.Response.write ~flush:false (fun w -> C.Response.write_body w body) resp oc
      >>= fun () ->
      C.IO.flush oc >>= fun () ->
      Unix.close fd;
      return_unit
  in
  let req =
    let h = Cohttp.Header.add (Cohttp.Header.init ()) "content-length" "0" in
    Cohttp.Request.make ~meth:`GET ~headers:h
      (Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port ~path:"/" ())
  in
  let one_request () =
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.set_nonblock s;
    Io.connect_m s (Unix.ADDR_INET (loopback, port)) >>= fun () ->
    let ic = C.IO.make_ic s and oc = C.IO.make_oc s in
    C.Request.write ~flush:false (fun _ -> return_unit) req oc >>= fun () ->
    C.IO.flush oc >>= fun () ->
    C.Response.read ic >>= function
    | `Eof | `Invalid _ -> Unix.close s; fail (Failure "bad")
    | `Ok r ->
      let reader = C.Response.make_body_reader r ic in
      let rec drain () =
        C.Response.read_body_chunk reader >>= function
        | Cohttp.Transfer.Done | Cohttp.Transfer.Final_chunk _ -> return_unit
        | Cohttp.Transfer.Chunk _ -> drain ()
      in
      drain () >>= fun () -> Unix.close s; return_unit
  in
  let client () =
    let rec loop i = if i = 0 then return_unit else one_request () >>= fun () -> loop (i - 1) in
    loop reqs
  in
  let rec accept_loop n =
    if n = 0 then return_unit
    else Io.accept_m ls >>= fun (c, _) -> Unix.set_nonblock c;
         ignore (async (fun () -> handle c)); accept_loop (n - 1)
  in
  let t0 = Unix.gettimeofday () in
  run (fun () ->
    both (accept_loop (conns * reqs)) (join (List.init conns (fun _ -> client ())))
    >>= fun _ -> return_unit);
  Unix.close ls;
  Unix.gettimeofday () -. t0

let () =
  Printf.printf "HTTP cohttp native on Lwt_effects: %d conn x %d req\n\n%!" conns
    reqs;
  Printf.printf "-- keep-alive --\n%!";
  report "cohttp / Lwt_effects (epoll)" (bench_native ());
  report "cohttp / Lwt_effects (io_uring)" (bench_native_uring ());
  Printf.printf "-- new connection per request (comparable to bench.ml) --\n%!";
  report "cohttp / Lwt_effects (epoll, newconn)" (bench_native_newconn ())
