(* HTTP throughput with cohttp: an in-process server answers a fixed body to
   GET /, hit by [conns] concurrent client fibers doing [reqs] requests each.

   The interesting comparison: the *same* cohttp-lwt-unix code, run under
   Lwt_main vs under the Lwt_effects scheduler (via the Lwt interop) — does the
   cheaper bind/scheduling speed up a real HTTP stack? A cohttp-eio variant is
   included as an external reference. *)

let conns = 50
let reqs = 200
let total = conns * reqs

let report name dt =
  Printf.printf "  %-30s %8.3f s  %10.0f req/s\n%!" name dt
    (float_of_int total /. dt)

(* ------------------------------------------------------------------ *)
(* cohttp-lwt-unix scenario (shared by the Lwt_main and Lwt_effects runs) *)
(* ------------------------------------------------------------------ *)

module LServer = Cohttp_lwt_unix.Server
module LClient = Cohttp_lwt_unix.Client

let lwt_scenario ~port () =
  let open Lwt.Infix in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port) in
  let stop, do_stop = Lwt.wait () in
  let callback _conn _req _body = LServer.respond_string ~status:`OK ~body:"hello" () in
  let srv = LServer.create ~stop ~mode:(`TCP (`Port port)) (LServer.make ~callback ()) in
  let client () =
    let rec loop i =
      if i = 0 then Lwt.return_unit
      else
        LClient.get uri >>= fun (_resp, body) ->
        Cohttp_lwt.Body.drain_body body >>= fun () -> loop (i - 1)
    in
    loop reqs
  in
  Lwt_unix.sleep 0.3 >>= fun () ->
  let t0 = Unix.gettimeofday () in
  Lwt.join (List.init conns (fun _ -> client ())) >>= fun () ->
  let dt = Unix.gettimeofday () -. t0 in
  Lwt.wakeup do_stop ();
  srv >>= fun () -> Lwt.return dt

let run_lwt ~port = Lwt_main.run (lwt_scenario ~port ())

let run_lwt_effects ~port =
  Lwt_effects.run (fun () ->
    Lwt_effects.return (Lwt_effects.await_lwt (lwt_scenario ~port ())))

(* ------------------------------------------------------------------ *)
(* cohttp-eio                                                         *)
(* ------------------------------------------------------------------ *)

let run_eio ~port =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let dt = ref 0.0 in
  Eio.Switch.run (fun sw ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in
    let stop, do_stop = Eio.Promise.create () in
    let handler _conn _req _body =
      Cohttp_eio.Server.respond_string ~status:`OK ~body:"hello" ()
    in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket
        (Cohttp_eio.Server.make ~callback:handler ()));
    let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/" port) in
    let client () =
      let c = Cohttp_eio.Client.make ~https:None net in
      for _ = 1 to reqs do
        Eio.Switch.run (fun sw ->
          let _resp, body = Cohttp_eio.Client.get ~sw c uri in
          ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int))
      done
    in
    let t0 = Unix.gettimeofday () in
    Eio.Fiber.all (List.init conns (fun _ -> client));
    dt := Unix.gettimeofday () -. t0;
    Eio.Promise.resolve do_stop ());
  !dt

(* ------------------------------------------------------------------ *)

let () =
  Printf.printf "HTTP cohttp: %d connections x %d requests (GET /)\n\n%!" conns reqs;
  report "cohttp-lwt-unix (Lwt_main)" (run_lwt ~port:18931);
  report "cohttp-lwt-unix (Lwt_effects)" (run_lwt_effects ~port:18932);
  report "cohttp-eio" (run_eio ~port:18933)
