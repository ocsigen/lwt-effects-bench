(* The cohttp-lwt-unix benchmark server of ocaml-multicore/retro-httpaf-bench,
   reproduced verbatim (cohttp_lwt_unix.ml) with two marked additions:
   - [-u] installs the io_uring engine (Lwt_uring.set) instead of libev;
   - a "/plaintext" route ("Hello, World!"), for the httpcats-protocol runs. *)

let text = Alice.text
let plaintext = "Hello, World!"

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
      Lwt.pause () >>= fun () ->
      match Uri.path uri with
      | "/" -> Server.respond_string ~headers ~status:`OK ~body:text ()
      | "/plaintext" ->
        Server.respond_string ~headers:pt_headers ~status:`OK ~body:plaintext ()
      | "/exit" -> exit 0
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
