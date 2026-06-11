(* Echo TCP, many concurrent connections.

   A loopback TCP server accepts [conns] connections; each is echoed by its own
   handler fiber ([msgs] messages of [size] bytes). [conns] client fibers connect
   and ping-pong [msgs] times each. Everything runs concurrently in one process,
   so this stresses concurrency/scalability, not just per-call latency.

   The Lwt configuration uses ONLY the public Lwt API; which core it runs on
   (classic or effect-based) is the [vendor/lwt] checkout. Set
   [BENCH_CORE=classic|effects] to label the output. TWO-PASS EXECUTION:
   [Lwt_uring.set ()] is process-global, so the default-engine run and
   Eio/Miou are measured first, then the engine is installed once.

   Reported: total time and round-trips per second (conns * msgs round-trips). *)

let conns = 100
let msgs = 1000
let size = 64
let total_rt = conns * msgs

let measure name (f : unit -> unit) =
  let t0 = Unix.gettimeofday () in
  f ();
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "  %-24s %8.3f s  %12.0f rt/s\n%!" name dt
    (float_of_int total_rt /. dt)

let loopback = Unix.inet_addr_loopback

let make_listener () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (loopback, 0));
  Unix.listen s 1024;
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | Unix.ADDR_UNIX _ -> failwith "expected inet address"
  in
  (s, port)

(* ------------------------------------------------------------------ *)
(* Lwt                                                                *)
(* ------------------------------------------------------------------ *)

let bench_lwt () =
  let open Lwt.Infix in
  let ls, port = make_listener () in
  Unix.set_nonblock ls;
  let lls = Lwt_unix.of_unix_file_descr ls in
  let msg = Bytes.make size 'x' in
  let rec write_all fd off len =
    if len = 0 then Lwt.return_unit
    else Lwt_unix.write fd msg off len >>= fun n -> write_all fd (off + n) (len - n)
  in
  let rec read_exact fd buf off len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_unix.read fd buf off len >>= fun n ->
      if n = 0 then Lwt.fail End_of_file else read_exact fd buf (off + n) (len - n)
  in
  let handler fd =
    let buf = Bytes.create size in
    let rec loop i =
      if i = 0 then Lwt_unix.close fd
      else read_exact fd buf 0 size >>= fun () -> write_all fd 0 size >>= fun () -> loop (i - 1)
    in
    loop msgs
  in
  let server () =
    let rec acc n hs =
      if n = 0 then Lwt.join hs
      else Lwt_unix.accept lls >>= fun (c, _) -> acc (n - 1) (handler c :: hs)
    in
    acc conns []
  in
  let client () =
    let s = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Lwt_unix.connect s (Unix.ADDR_INET (loopback, port)) >>= fun () ->
    let buf = Bytes.create size in
    let rec loop i =
      if i = 0 then Lwt_unix.close s
      else write_all s 0 size >>= fun () -> read_exact s buf 0 size >>= fun () -> loop (i - 1)
    in
    loop msgs
  in
  Lwt_main.run
    (Lwt.join [ server (); Lwt.join (List.init conns (fun _ -> client ())) ]);
  Lwt_main.run (Lwt_unix.close lls)

(* ------------------------------------------------------------------ *)
(* Eio (eio_linux: io_uring)                                          *)
(* ------------------------------------------------------------------ *)

let bench_eio () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let listening =
    Eio.Net.listen ~sw ~backlog:1024 ~reuse_addr:true net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr listening with
    | `Tcp (_, p) -> p
    | `Unix _ -> failwith "expected tcp address"
  in
  let msg = Cstruct.create size in
  Cstruct.memset msg (Char.code 'x');
  let handler flow =
    let buf = Cstruct.create size in
    for _ = 1 to msgs do
      Eio.Flow.read_exact flow buf;
      Eio.Flow.write flow [ msg ]
    done
  in
  let server () =
    Eio.Switch.run @@ fun sw2 ->
    for _ = 1 to conns do
      let flow, _ = Eio.Net.accept ~sw:sw2 listening in
      Eio.Fiber.fork ~sw:sw2 (fun () -> handler flow)
    done
  in
  let client () =
    Eio.Switch.run @@ fun sw2 ->
    let flow =
      Eio.Net.connect ~sw:sw2 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let buf = Cstruct.create size in
    for _ = 1 to msgs do
      Eio.Flow.write flow [ msg ];
      Eio.Flow.read_exact flow buf
    done
  in
  Eio.Fiber.both server (fun () ->
    Eio.Fiber.all (List.init conns (fun _ -> client)))

(* ------------------------------------------------------------------ *)
(* Miou (miou.unix)                                                   *)
(* ------------------------------------------------------------------ *)

let bench_miou () =
  let ls, port = make_listener () in
  Miou_unix.run ~domains:0 @@ fun () ->
  let lls = Miou_unix.of_file_descr ~non_blocking:true ls in
  let msg = String.make size 'x' in
  let read_exact fd buf =
    let off = ref 0 in
    while !off < size do
      let n = Miou_unix.read fd ~off:!off ~len:(size - !off) buf in
      if n = 0 then raise End_of_file;
      off := !off + n
    done
  in
  let handler fd =
    let buf = Bytes.create size in
    for _ = 1 to msgs do read_exact fd buf; Miou_unix.write fd msg done;
    Miou_unix.close fd
  in
  let client () =
    let s = Miou_unix.tcpv4 () in
    Miou_unix.connect s (Unix.ADDR_INET (loopback, port));
    let buf = Bytes.create size in
    for _ = 1 to msgs do Miou_unix.write s msg; read_exact s buf done;
    Miou_unix.close s
  in
  let server =
    Miou.async (fun () ->
      let hs = ref [] in
      for _ = 1 to conns do
        let c, _ = Miou_unix.accept lls in
        hs := Miou.async (fun () -> handler c) :: !hs
      done;
      List.iter (fun p -> Miou.await_exn p) !hs)
  in
  let clients = List.init conns (fun _ -> Miou.async client) in
  Miou.await_exn server;
  List.iter (fun p -> Miou.await_exn p) clients

(* ------------------------------------------------------------------ *)

let () =
  let core = try Sys.getenv "BENCH_CORE" with Not_found -> "?" in
  Printf.printf "Echo TCP: %d connections x %d messages of %d bytes (Lwt core: %s)\n\n%!"
    conns msgs size core;
  (* Pass 1: default engine + Eio + Miou. *)
  measure (Printf.sprintf "Lwt [%s]" core) bench_lwt;
  measure "Eio (io_uring)" bench_eio;
  measure "Miou" bench_miou;
  (* Pass 2: the io_uring engine, installed process-globally. *)
  Lwt_uring.set ();
  measure (Printf.sprintf "Lwt [%s]+uring" core) bench_lwt
