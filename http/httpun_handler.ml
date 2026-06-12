(* The request handler shared VERBATIM by the Lwt and Eio httpun servers.

   httpun (the maintained httpaf fork) has a single, scheduler-agnostic
   protocol engine (angstrom parser + faraday serializer + the
   [Server_connection] state machine); its per-scheduler adapters are thin
   Gluten I/O pumps. So the server_httpun_{lwt,eio} pair compares SCHEDULERS
   at constant HTTP stack — unlike cohttp-lwt-unix vs cohttp-eio, which are
   two largely independent implementations. Same routes as the cohttp
   servers: [/] (Alice, ~2 KB), [/plaintext] ("Hello, World!"), [/exit]. *)

let text = Alice.text
let plaintext = "Hello, World!"

let headers =
  Httpun.Headers.of_list
    [ ("content-length", string_of_int (String.length text)) ]

let pt_headers =
  Httpun.Headers.of_list
    [ ("content-length", string_of_int (String.length plaintext));
      ("content-type", "text/plain") ]

let nf_headers = Httpun.Headers.of_list [ ("content-length", "0") ]

let handle { Gluten.reqd; _ } =
  let request = Httpun.Reqd.request reqd in
  match request.Httpun.Request.target with
  | "/" ->
    Httpun.Reqd.respond_with_string reqd
      (Httpun.Response.create ~headers `OK)
      text
  | "/plaintext" ->
    Httpun.Reqd.respond_with_string reqd
      (Httpun.Response.create ~headers:pt_headers `OK)
      plaintext
  | "/exit" -> exit 0
  | _ ->
    Httpun.Reqd.respond_with_string reqd
      (Httpun.Response.create ~headers:nf_headers `Not_found)
      ""

(* Shared error handler, equally minimal on both sides. *)
let error_handler _addr ?request:_ _error start_response =
  Httpun.Body.Writer.close (start_response Httpun.Headers.empty)
