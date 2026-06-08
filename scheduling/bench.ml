(* Scheduling-bound workload (no I/O): [n] concurrent fibers each yield [k]
   times. This isolates the cost of suspension/resumption and promise
   allocation — where the effect-based bind/pause is expected to beat classic
   Lwt's per-step promise+callback machinery and its Lwt_main iteration.

   We report total time and minor-heap words allocated (per yield). *)

let n_fibers = 1000
let yields_each = 1000
let total = n_fibers * yields_each

let measure name (f : unit -> unit) =
  f ();
  (* warm up *)
  Gc.full_major ();
  let w0 = Gc.minor_words () in
  let t0 = Unix.gettimeofday () in
  f ();
  let dt = Unix.gettimeofday () -. t0 in
  let words = Gc.minor_words () -. w0 in
  Printf.printf "  %-24s %8.3f s  %8.1f ns/yield  %8.2f words/yield\n%!" name dt
    (dt /. float_of_int total *. 1e9)
    (words /. float_of_int total)

let bench_lwt () =
  let open Lwt.Infix in
  let rec loop i = if i = 0 then Lwt.return_unit else Lwt.pause () >>= fun () -> loop (i - 1) in
  Lwt_main.run (Lwt.join (List.init n_fibers (fun _ -> loop yields_each)))

let bench_eff () =
  let open Lwt_effects in
  run (fun () ->
    let ps =
      List.init n_fibers (fun _ ->
        async (fun () ->
          for _ = 1 to yields_each do
            yield ()
          done;
          return_unit))
    in
    List.iter (fun p -> await p) ps;
    return_unit)

let bench_eio () =
  Eio_main.run @@ fun _env ->
  Eio.Fiber.all
    (List.init n_fibers (fun _ () ->
       for _ = 1 to yields_each do
         Eio.Fiber.yield ()
       done))

let bench_miou () =
  Miou.run ~domains:0 (fun () ->
    let ps =
      List.init n_fibers (fun _ ->
        Miou.async (fun () ->
          for _ = 1 to yields_each do
            Miou.yield ()
          done))
    in
    List.iter (fun p -> Miou.await_exn p) ps)

let () =
  Printf.printf "Scheduling: %d fibers x %d yields = %d yields\n\n%!" n_fibers
    yields_each total;
  measure "Lwt" bench_lwt;
  measure "Lwt_effects" bench_eff;
  measure "Eio" bench_eio;
  measure "Miou" bench_miou
