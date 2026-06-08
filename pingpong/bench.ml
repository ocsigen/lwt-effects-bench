(* Ping-pong over a socketpair: a client and a server fiber exchange a message
   of [size] bytes back and forth [rt] times. The same workload is run on five
   schedulers/back ends, for a payload-size sweep:

   - classic Lwt (Lwt_unix, epoll);
   - Lwt_effects over Lwt_engine (epoll);
   - Lwt_effects over io_uring;
   - Eio (eio_linux: io_uring);
   - Miou (miou.unix).

   We report per-round-trip latency and the throughput (each round trip moves
   [size] bytes in each direction). *)

let sizes = [ 1; 64; 1024; 16384; 262144 ]

(* Round trips per size: keep total bytes moved roughly bounded. *)
let round_trips size = max 2000 (min 50000 (100_000_000 / size))

type result = { us_per_rt : float; mb_per_s : float }

let measure ~size ~rt (f : size:int -> rt:int -> unit) : result =
  f ~size ~rt:(min rt 200);
  (* warm up *)
  let t0 = Unix.gettimeofday () in
  f ~size ~rt;
  let dt = Unix.gettimeofday () -. t0 in
  let bytes = 2.0 *. float_of_int size *. float_of_int rt in
  { us_per_rt = dt /. float_of_int rt *. 1e6; mb_per_s = bytes /. dt /. 1e6 }

let pair () = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0

(* ------------------------------------------------------------------ *)
(* classic Lwt                                                        *)
(* ------------------------------------------------------------------ *)

let bench_lwt ~size ~rt =
  let a, b = pair () in
  let la = Lwt_unix.of_unix_file_descr a and lb = Lwt_unix.of_unix_file_descr b in
  let msg = Bytes.make size 'x' in
  let cbuf = Bytes.create size and sbuf = Bytes.create size in
  let open Lwt.Infix in
  let rec write_all fd buf off len =
    if len = 0 then Lwt.return_unit
    else Lwt_unix.write fd buf off len >>= fun n -> write_all fd buf (off + n) (len - n)
  in
  let rec read_exact fd buf off len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_unix.read fd buf off len >>= fun n ->
      if n = 0 then Lwt.fail End_of_file else read_exact fd buf (off + n) (len - n)
  in
  let rec client n =
    if n = 0 then Lwt.return_unit
    else
      write_all la msg 0 size >>= fun () ->
      read_exact la cbuf 0 size >>= fun () -> client (n - 1)
  in
  let rec server n =
    if n = 0 then Lwt.return_unit
    else
      read_exact lb sbuf 0 size >>= fun () ->
      write_all lb msg 0 size >>= fun () -> server (n - 1)
  in
  Lwt_main.run (Lwt.join [ client rt; server rt ]);
  Unix.close a;
  Unix.close b

(* ------------------------------------------------------------------ *)
(* Lwt_effects, monadic Compat style (the drop-in model: every          *)
(* interruptible call returns a promise; implicit concurrency preserved) *)
(* ------------------------------------------------------------------ *)

let bench_compat ~size ~rt =
  let open Lwt_effects in
  let open Lwt_effects.Compat in
  let a, b = pair () in
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  let msg = Bytes.make size 'x' in
  let cbuf = Bytes.create size and sbuf = Bytes.create size in
  let rec write_all fd off len =
    if len = 0 then return_unit
    else Io.write_m fd msg off len >>= fun n -> write_all fd (off + n) (len - n)
  in
  let rec read_exact fd buf off len =
    if len = 0 then return_unit
    else
      Io.read_m fd buf off len >>= fun n ->
      if n = 0 then fail End_of_file else read_exact fd buf (off + n) (len - n)
  in
  let rec client n =
    if n = 0 then return_unit
    else
      write_all a 0 size >>= fun () ->
      read_exact a cbuf 0 size >>= fun () -> client (n - 1)
  in
  let rec server n =
    if n = 0 then return_unit
    else
      read_exact b sbuf 0 size >>= fun () ->
      write_all b 0 size >>= fun () -> server (n - 1)
  in
  run (fun () -> both (client rt) (server rt) >>= fun _ -> return_unit);
  Unix.close a;
  Unix.close b

(* Monadic Compat style over io_uring: async typing AND io_uring speed. *)
let bench_compat_uring ~size ~rt =
  let open Lwt_effects in
  let open Lwt_effects.Compat in
  let module U = Lwt_effects_uring in
  let a, b = pair () in
  let msg = Cstruct.create size in
  Cstruct.memset msg (Char.code 'x');
  let cbuf = Cstruct.create size and sbuf = Cstruct.create size in
  let rec write_all fd cs =
    if Cstruct.length cs = 0 then return_unit
    else U.Io.write_m fd cs >>= fun n -> write_all fd (Cstruct.shift cs n)
  in
  let rec read_exact fd cs =
    if Cstruct.length cs = 0 then return_unit
    else
      U.Io.read_m fd cs >>= fun n ->
      if n = 0 then fail End_of_file else read_exact fd (Cstruct.shift cs n)
  in
  let rec client n =
    if n = 0 then return_unit
    else write_all a msg >>= fun () -> read_exact a cbuf >>= fun () -> client (n - 1)
  in
  let rec server n =
    if n = 0 then return_unit
    else read_exact b sbuf >>= fun () -> write_all b msg >>= fun () -> server (n - 1)
  in
  U.run (fun () -> both (client rt) (server rt) >>= fun _ -> return_unit);
  Unix.close a;
  Unix.close b

(* ------------------------------------------------------------------ *)
(* Lwt_effects, direct style (effect bind + await; loses async typing) *)
(* ------------------------------------------------------------------ *)

let bench_eff ~size ~rt =
  let open Lwt_effects in
  let a, b = pair () in
  Unix.set_nonblock a;
  Unix.set_nonblock b;
  let msg = Bytes.make size 'x' in
  let cbuf = Bytes.create size and sbuf = Bytes.create size in
  let write_all fd buf =
    let off = ref 0 in
    while !off < size do
      off := !off + Io.write fd buf !off (size - !off)
    done
  in
  let read_exact fd buf =
    let off = ref 0 in
    while !off < size do
      let n = Io.read fd buf !off (size - !off) in
      if n = 0 then raise End_of_file;
      off := !off + n
    done
  in
  run (fun () ->
    let c = async (fun () -> for _ = 1 to rt do write_all a msg; read_exact a cbuf done; return_unit) in
    let s = async (fun () -> for _ = 1 to rt do read_exact b sbuf; write_all b msg done; return_unit) in
    both c s >>= fun _ -> return_unit);
  Unix.close a;
  Unix.close b

(* ------------------------------------------------------------------ *)
(* Lwt_effects over io_uring                                          *)
(* ------------------------------------------------------------------ *)

let bench_uring ~size ~rt =
  let open Lwt_effects in
  let a, b = pair () in
  let msg = Cstruct.create size in
  Cstruct.memset msg (Char.code 'x');
  let cbuf = Cstruct.create size and sbuf = Cstruct.create size in
  let write_all fd cs =
    let cs = ref cs in
    while Cstruct.length !cs > 0 do
      cs := Cstruct.shift !cs (Lwt_effects_uring.Io.write fd !cs)
    done
  in
  let read_exact fd cs =
    let cs = ref cs in
    while Cstruct.length !cs > 0 do
      let n = Lwt_effects_uring.Io.read fd !cs in
      if n = 0 then raise End_of_file;
      cs := Cstruct.shift !cs n
    done
  in
  Lwt_effects_uring.run (fun () ->
    let c = async (fun () -> for _ = 1 to rt do write_all a msg; read_exact a cbuf done; return_unit) in
    let s = async (fun () -> for _ = 1 to rt do read_exact b sbuf; write_all b msg done; return_unit) in
    both c s >>= fun _ -> return_unit);
  Unix.close a;
  Unix.close b

(* ------------------------------------------------------------------ *)
(* Eio (eio_linux: io_uring)                                          *)
(* ------------------------------------------------------------------ *)

let bench_eio ~size ~rt =
  let a, b = pair () in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let fa = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true a in
  let fb = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true b in
  let msg = Cstruct.create size in
  Cstruct.memset msg (Char.code 'x');
  let cbuf = Cstruct.create size and sbuf = Cstruct.create size in
  let client () =
    for _ = 1 to rt do
      Eio.Flow.write fa [ msg ];
      Eio.Flow.read_exact fa cbuf
    done
  in
  let server () =
    for _ = 1 to rt do
      Eio.Flow.read_exact fb sbuf;
      Eio.Flow.write fb [ msg ]
    done
  in
  Eio.Fiber.both client server

(* ------------------------------------------------------------------ *)
(* Miou (miou.unix)                                                   *)
(* ------------------------------------------------------------------ *)

let bench_miou ~size ~rt =
  let a, b = pair () in
  Miou_unix.run ~domains:0 @@ fun () ->
  let fa = Miou_unix.of_file_descr ~non_blocking:true a
  and fb = Miou_unix.of_file_descr ~non_blocking:true b in
  let msg = String.make size 'x' in
  let cbuf = Bytes.create size and sbuf = Bytes.create size in
  let read_exact fd buf =
    let off = ref 0 in
    while !off < size do
      let n = Miou_unix.read fd ~off:!off ~len:(size - !off) buf in
      if n = 0 then raise End_of_file;
      off := !off + n
    done
  in
  let client = Miou.async (fun () ->
    for _ = 1 to rt do Miou_unix.write fa msg; read_exact fa cbuf done)
  in
  let server = Miou.async (fun () ->
    for _ = 1 to rt do read_exact fb sbuf; Miou_unix.write fb msg done)
  in
  Miou.await_exn client;
  Miou.await_exn server

(* ------------------------------------------------------------------ *)

let backends =
  [
    ("Lwt (epoll)", bench_lwt);
    ("Lwt_effects Compat (epoll)", bench_compat);
    ("Lwt_effects Compat (io_uring)", bench_compat_uring);
    ("Lwt_effects direct (epoll)", bench_eff);
    ("Lwt_effects direct (io_uring)", bench_uring);
    ("Eio (io_uring)", bench_eio);
    ("Miou", bench_miou);
  ]

let () =
  Printf.printf "Ping-pong over a socketpair (payload-size sweep)\n\n%!";
  Printf.printf "%-24s %10s %12s %14s\n" "backend" "size" "us/round-trip"
    "throughput MB/s";
  List.iter
    (fun size ->
      let rt = round_trips size in
      List.iter
        (fun (name, f) ->
          let r = measure ~size ~rt f in
          Printf.printf "%-24s %10d %12.2f %14.1f\n%!" name size r.us_per_rt
            r.mb_per_s)
        backends;
      print_newline ())
    sizes
