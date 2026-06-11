(* Scheduling-bound workload (no I/O): [n] concurrent fibers each yield [k]
   times. This isolates the cost of suspension/resumption and promise
   allocation.

   The Lwt configurations use ONLY the public Lwt API: which core they run on
   (the classic one or the effect-based one) is decided by the [vendor/lwt]
   checkout — that is the whole point of the in-place core swap. Set
   [BENCH_CORE=classic|effects] so the output is labelled.

   - Lwt (monadic): 1000 fibers = 1000 concurrent [pause]-chains under
     [Lwt_main.run].
   - Lwt_direct: the direct-style surface over the same core
     ([spawn]/[yield]).
   - Eio (eio_main) and Miou for reference.

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

let bench_lwt_direct () =
  Lwt_main.run
    (Lwt.join
       (List.init n_fibers (fun _ ->
          Lwt_direct.spawn (fun () ->
            for _ = 1 to yields_each do
              Lwt_direct.yield ()
            done))))

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
  let core = try Sys.getenv "BENCH_CORE" with Not_found -> "?" in
  Printf.printf "Scheduling: %d fibers x %d yields = %d yields (Lwt core: %s)\n\n%!"
    n_fibers yields_each total core;
  measure (Printf.sprintf "Lwt [%s]" core) bench_lwt;
  measure (Printf.sprintf "Lwt_direct [%s]" core) bench_lwt_direct;
  measure "Eio" bench_eio;
  measure "Miou" bench_miou
