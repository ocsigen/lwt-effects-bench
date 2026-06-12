(* The cohttp-eio benchmark server of ocaml-multicore/retro-httpaf-bench,
   reproduced from cohttp_eio.ml with three marked changes:
   - debug logging OFF (the original sets Cohttp_eio.src to Debug, which is
     not representative for a benchmark);
   - a "/plaintext" route, for the httpcats-protocol runs;
   - listens on loopback like the original. *)

let text = Alice.text
let plaintext = "Hello, World!"

open Cohttp_eio

let handler _socket request _body =
  match Http.Request.resource request with
  | "/" -> Server.respond_string ~status:`OK ~body:text ()
  | "/plaintext" ->
    Server.respond_string
      ~headers:(Http.Header.of_list [ ("content-type", "text/plain") ])
      ~status:`OK ~body:plaintext ()
  | "/html" ->
    let body = Eio.Flow.string_source text in
    Server.respond () ~status:`OK
      ~headers:(Http.Header.of_list [ ("content-type", "text/html") ])
      ~body
  | _ -> Server.respond_string ~status:`Not_found ~body:"" ()

let log_warning ex = Logs.warn (fun f -> f "%a" Eio.Exn.pp ex)

let () =
  let port = ref 8080 in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number(8080 by default)") ]
    ignore "An HTTP/1.1 server";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, !port))
  and server = Server.make ~callback:handler () in
  Server.run socket server ~on_error:log_warning
