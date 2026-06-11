(* Ping-pong over a socketpair: a client and a server fiber exchange a message
   of [size] bytes back and forth [rt] times, for a payload-size sweep.

   The Lwt configurations use ONLY the public Lwt API; which core they run on
   (classic or effect-based) is the [vendor/lwt] checkout. Set
   [BENCH_CORE=classic|effects] to label the output. Two Lwt I/O variants:

   - bytes: [Lwt_unix.read/write] (under io_uring this path pays a
     bytes<->Cstruct copy per call — worst case);
   - bigarray: [Lwt_bytes.read/write], the path [Lwt_io] (and therefore
     cohttp & co) actually uses — copy-free under io_uring.

   TWO-PASS EXECUTION: [Lwt_uring.set ()] installs the io_uring engine
   process-globally with no way back, so the default-engine configurations and
   Eio/Miou are measured FIRST, then the engine is installed once, then the
   io_uring rows. *)

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
(* Lwt, bytes path (Lwt_unix.read/write)                              *)
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
(* Lwt, bigarray path (Lwt_bytes.read/write — the Lwt_io/cohttp path) *)
(* ------------------------------------------------------------------ *)

let bench_lwt_bigarray ~size ~rt =
  let a, b = pair () in
  let la = Lwt_unix.of_unix_file_descr a and lb = Lwt_unix.of_unix_file_descr b in
  let msg = Lwt_bytes.create size in
  Lwt_bytes.fill msg 0 size 'x';
  let cbuf = Lwt_bytes.create size and sbuf = Lwt_bytes.create size in
  let open Lwt.Infix in
  let rec write_all fd buf off len =
    if len = 0 then Lwt.return_unit
    else Lwt_bytes.write fd buf off len >>= fun n -> write_all fd buf (off + n) (len - n)
  in
  let rec read_exact fd buf off len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_bytes.read fd buf off len >>= fun n ->
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
  let client =
    Miou.async (fun () ->
      for _ = 1 to rt do
        Miou_unix.write fa msg;
        read_exact fa cbuf
      done)
  in
  let server =
    Miou.async (fun () ->
      for _ = 1 to rt do
        read_exact fb sbuf;
        Miou_unix.write fb msg
      done)
  in
  List.iter (fun p -> Miou.await_exn p) [ client; server ];
  Miou_unix.close fa;
  Miou_unix.close fb

(* ------------------------------------------------------------------ *)

let run_config name f =
  List.iter
    (fun size ->
      let rt = round_trips size in
      let r = measure ~size ~rt f in
      Printf.printf "%-30s %10d %12.2f %14.1f\n%!" name size r.us_per_rt
        r.mb_per_s)
    sizes

let () =
  let core = try Sys.getenv "BENCH_CORE" with Not_found -> "?" in
  Printf.printf "Ping-pong over a socketpair (payload sweep; Lwt core: %s)\n\n%!"
    core;
  Printf.printf "%-30s %10s %12s %14s\n" "backend" "size" "us/round-trip"
    "MB/s";
  (* Pass 1: default engine + Eio + Miou. *)
  run_config (Printf.sprintf "Lwt bytes [%s]" core) bench_lwt;
  run_config (Printf.sprintf "Lwt bigarray [%s]" core) bench_lwt_bigarray;
  run_config "Eio (io_uring)" bench_eio;
  run_config "Miou" bench_miou;
  (* Pass 2: the io_uring engine, installed process-globally. *)
  Lwt_uring.set ();
  run_config (Printf.sprintf "Lwt bytes [%s]+uring" core) bench_lwt;
  run_config (Printf.sprintf "Lwt bigarray [%s]+uring" core) bench_lwt_bigarray
