(* Monadic bind cost (Lwt-family only — Eio and Miou have no bind):

   - resolved chain: [bind (return v) f] repeated — the fast path;
   - suspension chain: [bind (pause ()) f] repeated — a pending bind per step,
     i.e. one promise + one callback per step on classic Lwt (plus its proxy
     machinery) — the server-loop pattern.

   Uses ONLY the public Lwt API; the core measured is the [vendor/lwt]
   checkout. Set [BENCH_CORE=classic|effects] to label the output. *)

let chain_len = 1000
let resolved_repeats = 5000
let suspended_repeats = 1000

let measure name ~ops (f : unit -> unit) =
  f ();
  (* warm up *)
  Gc.full_major ();
  let w0 = Gc.minor_words () in
  let t0 = Unix.gettimeofday () in
  f ();
  let dt = Unix.gettimeofday () -. t0 in
  let words = Gc.minor_words () -. w0 in
  Printf.printf "  %-28s %8.3f s  %8.1f ns/op  %8.2f words/op\n%!" name dt
    (dt /. float_of_int ops *. 1e9)
    (words /. float_of_int ops)

let rec sum n acc =
  if n = 0 then Lwt.return acc
  else Lwt.bind (Lwt.return (acc + n)) (fun acc -> sum (n - 1) acc)

let rec pauses n =
  if n = 0 then Lwt.return_unit
  else Lwt.bind (Lwt.pause ()) (fun () -> pauses (n - 1))

let () =
  let core = try Sys.getenv "BENCH_CORE" with Not_found -> "?" in
  Printf.printf "Monadic bind chains (Lwt core: %s)\n\n%!" core;
  let total = ref 0 in
  measure
    (Printf.sprintf "resolved bind [%s]" core)
    ~ops:(chain_len * resolved_repeats)
    (fun () ->
      for _ = 1 to resolved_repeats do
        total := !total + Lwt_main.run (sum chain_len 0)
      done);
  ignore !total;
  measure
    (Printf.sprintf "suspended bind [%s]" core)
    ~ops:(chain_len * suspended_repeats)
    (fun () ->
      for _ = 1 to suspended_repeats do
        Lwt_main.run (pauses chain_len)
      done)
