(* The cohttp-lwt-unix benchmark server of ocaml-multicore/retro-httpaf-bench,
   reproduced verbatim (cohttp_lwt_unix.ml) with two marked additions:
   - [-u] installs the io_uring engine (Lwt_uring.set) instead of libev;
   - a "/plaintext" route ("Hello, World!"), for the httpcats-protocol runs. *)

let text = Alice.text
let plaintext = "Hello, World!"

(* Diagnostic toggle: NOPAUSE=1 skips the per-request [Lwt.pause ()] to test
   whether the pause machinery drives the effect core's major-GC marking. *)
let nopause = try Sys.getenv "NOPAUSE" = "1" with Not_found -> false

module BenchmarkServer = struct
  let benchmark =
    let headers =
      Cohttp.Header.of_list
        [ ("content-length", Int.to_string (String.length text)) ]
    in
    let pt_headers =
      Cohttp.Header.of_list
        [ ("content-length", Int.to_string (String.length plaintext));
          ("content-type", "text/plain") ]
    in
    let handler _conn req _body =
      let open Lwt in
      let open Cohttp_lwt_unix in
      let uri = Request.uri req in
      (if nopause then Lwt.return_unit else Lwt.pause ()) >>= fun () ->
      match Uri.path uri with
      | "/" -> Server.respond_string ~headers ~status:`OK ~body:text ()
      | "/plaintext" ->
        Server.respond_string ~headers:pt_headers ~status:`OK ~body:plaintext ()
      | "/exit" -> exit 0
      | "/gc" ->
        (* True live set under load: full major collects floating garbage,
           then live_words is the genuinely-reachable size. *)
        Gc.full_major ();
        let s = Gc.stat () in
        Server.respond_string ~status:`OK
          ~body:(Printf.sprintf "live_words=%d heap_words=%d top_heap_words=%d\n"
                   s.live_words s.heap_words s.top_heap_words) ()
      | _ -> Server.respond_not_found ()
    in
    handler
end

let main port max_active io_buf uring =
  let handler = BenchmarkServer.benchmark in
  if uring then Lwt_uring.set () else Lwt_engine.set (new Lwt_engine.libev ());
  if max_active > 0 then Conduit_lwt_unix.set_max_active max_active;
  Lwt_io.set_default_buffer_size io_buf;
  let open Cohttp_lwt_unix in
  let server =
    Server.create ~ctx:(Net.init ()) ~mode:(`TCP (`Port port))
      (Server.make ~callback:handler ())
  in
  Lwt_main.run server

(* Deterministic per-request cost signal (thermal-insensitive), dumped on
   [/exit]: cumulative minor words allocated + GC collection counts. Divide by
   wrk's reported request count to compare cores. *)
let () =
  at_exit (fun () ->
    let s = Gc.quick_stat () in
    Printf.eprintf
      "GCDUMP minor_words=%.0f promoted_words=%.0f major_words=%.0f \
       minor_colls=%d major_colls=%d compactions=%d \
       heap_words=%d top_heap_words=%d live_words=%d\n%!"
      (Gc.minor_words ()) s.promoted_words s.major_words
      s.minor_collections s.major_collections s.compactions
      s.heap_words s.top_heap_words (Gc.stat ()).live_words)

let () =
  let port = ref 8080 in
  let max_active = ref 0 in
  let io_buf = ref 0x10_000 in
  let uring = ref false in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number (8080 by default)");
      ("-m", Arg.Set_int max_active, " Set max active connections (unlimited by default)");
      ("-i", Arg.Set_int io_buf, " Lwt_io default buffer size (64k by default)");
      ("-u", Arg.Set uring, " Use the io_uring engine instead of libev") ]
    ignore "Responds to requests with a fixed string for benchmarking purposes.";
  main !port !max_active !io_buf !uring
