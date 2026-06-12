(* httpun on Eio (eio_linux: io_uring) — same protocol engine and request
   handler (Httpun_handler) as server_httpun_lwt.ml: a scheduler comparison
   at constant HTTP stack. *)

let main port =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~reuse_addr:true ~backlog:1024 ~sw net addr in
  let request_handler _addr gluten_reqd = Httpun_handler.handle gluten_reqd in
  let connection_handler =
    Httpun_eio.Server.create_connection_handler ~request_handler
      ~error_handler:Httpun_handler.error_handler
  in
  while true do
    Eio.Net.accept_fork socket ~sw
      ~on_error:(fun _ -> ())
      (fun flow client_addr -> connection_handler ~sw client_addr flow)
  done

let () =
  let port = ref 8080 in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number (8080 by default)") ]
    ignore "httpun-eio benchmark server (same handler as the Lwt variant).";
  main !port
