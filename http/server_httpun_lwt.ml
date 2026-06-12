(* httpun on Lwt — same protocol engine and request handler (Httpun_handler)
   as server_httpun_eio.ml: a scheduler comparison at constant HTTP stack.
   [-u] installs the io_uring engine instead of libev. *)

let main port uring =
  if uring then Lwt_uring.set () else Lwt_engine.set (new Lwt_engine.libev ());
  let listen_address = Unix.(ADDR_INET (inet_addr_loopback, port)) in
  let request_handler _addr gluten_reqd = Httpun_handler.handle gluten_reqd in
  Lwt_main.run
    (let open Lwt.Infix in
     Lwt_io.establish_server_with_client_socket ~backlog:1024 listen_address
       (Httpun_lwt_unix.Server.create_connection_handler ~request_handler
          ~error_handler:Httpun_handler.error_handler)
     >>= fun _server -> fst (Lwt.wait ()))

let () =
  let port = ref 8080 in
  let uring = ref false in
  Arg.parse
    [ ("-p", Arg.Set_int port, " Listening port number (8080 by default)");
      ("-u", Arg.Set uring, " Use the io_uring engine instead of libev") ]
    ignore "httpun-lwt benchmark server (same handler as the Eio variant).";
  main !port !uring
