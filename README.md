# Lwt on effects — the in-place core swap, benchmarked

**2026-06-12 (corrected campaign).** [Lwt](https://github.com/ocsigen/lwt)'s
core has been reimplemented over OCaml 5 effects, **in place**:
`src/core/lwt.ml` on the
[`lwt-effects-core` branch](https://github.com/ocsigen/lwt/tree/lwt-effects-core)
is the effect engine, behind the historical `lwt.mli` (unchanged but for three
scheduler hooks under `Lwt.Private`). It is a true drop-in: the **whole
historical test suite passes natively** (`test/core` 705, `test/unix` 233, the
ppx, `Lwt_react`, `Lwt_direct`, `lwt_uring` suites), and the unmodified
ecosystem recompiles and runs — cohttp-lwt-unix, ocsigenserver, Eliom,
Ocsigen Start.

The earlier proof-of-concept report (separate `lwt_effects` package, two bind
flavours, hand-written cohttp backend) is preserved unchanged in
**[README-2026-06-poc.md](README-2026-06-poc.md)**; the POC configurations
were re-measured during this campaign to calibrate against it (see
[Comparing with the POC](#comparing-with-the-poc)).

The realistic HTTP suite ([§6](#6-realistic-http-benchmarks--replicated-from-existing-suites))
earned its keep: it surfaced a **waiter leak in the effect core's
`choose`/`pick`** that no in-process micro-benchmark showed, fixed the same
day (`856e73f18`) — the numbers in §6 are post-fix.

> ⚠️ Micro-benchmarks, one (laptop) machine, loopback I/O. A first run of this
> campaign (2026-06-11) measured the two cores in separate, non-interleaved
> passes and was skewed by varying machine load — it wrongly suggested
> regressions. The numbers below use a **strict A/B protocol**: one binary per
> core, saved, then run *alternating* in the same machine window. Two more
> traps cost us a day each: after ~12 min of continuous benching this laptop
> throttles (~85 °C, `powersave` governor) and throws 100–700 ms p99 spikes
> at whichever server runs last; and a leak only shows up under minutes of
> *external* sustained load. Treat <10 % as noise; ratios over absolutes.

## What is being compared

The drop-in property makes the methodology simple: **every Lwt configuration
is the same benchmark source, public Lwt API only** — what changes is which
lwt is linked:

| label | lwt |
|---|---|
| `classic` | the [`lwt-uring` branch](https://github.com/ocsigen/lwt/tree/lwt-uring): historical core + the transparent io_uring engine |
| `effects` | the [`lwt-effects-core` branch](https://github.com/ocsigen/lwt/tree/lwt-effects-core): effect-based core + the same engine |

A third Lwt flavour appears in some charts: **lab** — the
[`lwt-effects-lab` branch](https://github.com/ocsigen/lwt/tree/lwt-effects-lab)'s
*semantics-breaking* configurations (cheap suspending effect bind, direct
style, private io_uring ring, no `Lwt_unix`). It is the "how fast could it go
if we gave up Lwt's semantics and API" reference — kept experimental,
deliberately not what the swap ships.

**Eio** (`eio_main` 1.3, io_uring via `eio_linux`) and **Miou** (0.6,
`miou.unix` — which multiplexes with `ppoll` on this machine; its `select`
implementation is only the fallback when `ppoll` is unavailable) are the
external references.

**Chart colour code**: colour = scheduler family — **blue** = effect core
(vivid for io_uring, light for epoll), **blue-green** = classic core (dark
for io_uring, light for epoll), **dark blue-grey** = lab; orange = Eio (io_uring);
purple = Miou (ppoll — verified with strace; select is only its fallback). The vivid-blue bar (effect core + io_uring) is the
configuration this work ships.

## Results

### 1. Monadic bind

![bind](charts/swap-bind.svg)

*(⚠ chart not yet regenerated: it still shows the pre-cadence 87 ns
suspended-bind bar — the table below is the current truth.)*

(Re-measured 2026-06-12 evening with the final core — leak fix + pause
cadence, see the history note below; 2 interleaved rounds, pinned.)

| chain of binds (ns/op, words/op) | classic core | effect core | lab (breaking) |
|---|---|---|---|
| resolved (`bind (return v) f`) | 10.6–11.4 / 25 | **5.1–5.2 / 9** (~2×) | 9.5 / 9 |
| suspended (`bind (pause ()) f`, through `Lwt_main.run`) | 1404–1430 / 88 | **1262–1284 / 71** (~10 %) | 96 / 52 |

**Resolved bind — the common case of hot monadic code — is ~2× faster with
a third of the allocation.** This is the cost of *every* already-resolved
`>>=` in every Lwt program: the historical bind's promise + callback + proxy
bookkeeping vs one lean promise. Tail-recursive bind loops are O(1) in live
memory (reverse-merge proxies; measured flat over 2M steps, slightly below
the classic core), and the full Lwt semantics are preserved (705-test core
suite, ppx, Lwt_react — unchanged).

**A history note on the suspended row — an earlier version of this table
claimed 87 ns (~14.7×) for the effect core.** That number was real but
measured on a core with a conformance bug: it served successive `pause`
generations back-to-back *without ever running the I/O engine* — under
classic Lwt's documented behaviour, every pause generation interleaves with
one engine iteration (that lap, ~1.3 µs of libev under `Lwt_main.run`, is
exactly why the classic core measures 1404 ns here), and on the buggy core a
`let rec loop () = pause () >>= loop` would have starved I/O forever. The fix
(`7c7f9a438`) makes the effect core run classic's lap structure; the
suspended bind through the full main loop is now lap-dominated for both
cores, the effect core's leaner machinery showing as ~10 % and 17 fewer
words. The engine-free figure remains legitimate only where there is no
engine: under bare `Lwt.Private.scheduler_run`, and for the lab scheduler
(the 96 ns column), which doesn't drive an engine at all. Where suspension
cost matters at scale, the *pause storm* below shows the batched picture —
one lap amortized over a thousand resumptions.

### 2. Scheduling (no I/O)

![scheduling](charts/swap-scheduling.svg)

(Re-measured 2026-06-12 evening with the final core; 2 interleaved rounds,
pinned.)

| 1000 fibers × 1000 yields | ns/yield | words/yield |
|---|---|---|
| lab: breaking direct yield | 59 | 9 |
| **Lwt_direct (effect core)** | **69–76** | **16** |
| Eio | 83–93 | 40 |
| Lwt_direct (classic core) | 132–156 | 18 |
| Lwt (effect core, `pause`) | 222–237 | 61 |
| Lwt (classic core, `pause`) | 234–255 | 67 |
| Miou | 416–436 | 67 |

The effect core is at parity to ~8 % faster than the classic one on the
monadic `pause` storm (both now pay one engine lap per pause generation —
see §1 — amortized here over the 1000-fiber batch) — and **direct style on
the effect core is faster than Eio**, with the lowest allocation of the
table. `Lwt_direct` was re-plumbed onto the
core's own run queue (`Lwt.Private.scheduler_enqueue`): a yield is one queue
push/pop — no private task queue, no `Lwt_main` hook pump, no engine
round-trip per batch — essentially recovering the POC's direct-on-scheduler
bar (52–59 ns) behind `Lwt_direct`'s unchanged public API. (On the classic
core `Lwt_direct` keeps its hook-based implementation, hence the 130–151 ns.)

### 3. Ping-pong latency (socketpair, payload sweep)

![pingpong](charts/swap-pingpong.svg)

µs per round-trip, min over alternating runs ("bigarray" = the
`Lwt_bytes`/`Lwt_io` path; re-measured 2026-06-12 evening, final core):

| config | 1 B | 64 B | 1 KB | 16 KB | 256 KB |
|---|---|---|---|---|---|
| Lwt bigarray (classic, epoll) | 9.9 | 10.0 | 10.0 | 13.5 | 96.6 |
| Lwt bigarray (effects, epoll) | 9.6 | 9.6 | 9.7 | 13.1 | 99.5 |
| Lwt bigarray (classic, io_uring) | 7.4 | 7.0 | 7.5 | 10.8 | 78.8 |
| Lwt bigarray (effects, io_uring) | 7.3 | 6.8 | 7.1 | 10.6 | **75.2** |
| Eio (io_uring) | **6.4** | **6.6** | **6.4** | **9.8** | 76.4 |
| lab: breaking + own ring | 6.1 | — | — | — | — |
| Miou | 22.8 | 22.4 | 23.3 | 26.7 | 170.3 |

(The lab ping-pong figure is the POC report's, same machine — its harness
only measured the 1-byte point for that configuration.)

Effectively a three-way tie between the two Lwt cores on io_uring and Eio:
Eio keeps a small edge (≲1 µs) at the smallest payloads, the gap closes by
16 KB, and the effect core is the fastest of the table at 256 KB — unchanged
Lwt code *at Eio level*. (The bytes API still regresses at large payloads
under io_uring — the inherent copy; `Lwt_io`/cohttp use the bigarray path.)

### 4. Echo TCP — 100 concurrent connections

![echo](charts/swap-echo.svg)

(Re-measured 2026-06-12 evening with the final core; 2 interleaved rounds,
ranges over rounds — Eio is measured inside each binary run, so it has four
samples in the same windows.)

| config | round-trips/s |
|---|---|
| lab: breaking + own ring | **108 037** |
| Eio (io_uring) | 92.2k – 99.6k |
| Lwt (effect core, io_uring) | 92.3k – 98.7k |
| Lwt (classic core, io_uring) | 90.4k – 94.8k |
| Lwt (effect core, epoll) | 69.3k – 71.6k |
| Lwt (classic core, epoll) | 69.2k – 73.3k |
| Miou | 20.8k – 22.1k |

**Unchanged Lwt code on the transparent io_uring engine is in a statistical
tie with Eio** — the three io_uring rows overlap within window noise. (An
earlier version of this table, from a single window, read as Lwt +9 % over
Eio; with more rounds that was luck of the window — the honest claim is the
tie. Same for the epoll rows: the two cores are at parity there.) For
calibration, the POC's *private-ring* configurations re-measured during the
campaign: `Compat` + own ring 94.2k (≈ the transparent engine today),
direct-style + own ring 108k — the remaining direct-style margin is the
semantics trade the drop-in declines to make.

### 5. cohttp — an unmodified, real HTTP stack

![cohttp](charts/swap-cohttp.svg)

The same `cohttp-lwt-unix` 6.2.1, **untouched**, recompiled against each core
(opam pin), `Client.get`, new connection per request (best of 3 interleaved
rounds; this benchmark has the largest run-to-run variance; re-measured
2026-06-12 evening with the final core — it exercises the §6 waiter-leak fix
directly, conduit doing a `pick` per connection):

| config (best of 3 interleaved rounds) | classic | effect core |
|---|---|---|
| epoll | 6 105 | **6 557** (+7 %) |
| epoll + static resolver | 6 560 | **6 803** |
| io_uring (+ multishot accept on the effect core) | 6 964 | **7 486** (+7 %) |
| io_uring + static resolver | 7 671 | **8 174** (+7 %) |
| cohttp-eio | | 8 495 – 8 964 |

Four levers, found by syscall accounting (~13 syscalls and ~4 worker-pool
thread round-trips per request initially) and by the §6 realistic suite,
progressively closed the gap to cohttp-eio from ~25 % to **~5–9 %**:

1. **Multishot accept** (`IORING_ACCEPT_MULTISHOT`, via a locally patched
   ocaml-uring): one submission per listening socket, one completion per
   accepted connection — no accept(2), no fcntl per accept. It turned the
   previously *rejected* accept routing into a win (new-connection
   microbenchmark: libev 17.4k → connect+multishot 21.7k conn/s; single-shot
   accept had measured ~14k).
2. **`Lwt_unix.getaddrinfo` numeric fast path** (an lwt improvement): a
   numeric host with an all-digits port resolves synchronously
   (AI_NUMERICHOST), with no DNS, no worker-pool job — conduit resolves the
   host once per request.
3. **Static service resolver** (pure client configuration, `~ctx`): conduit's
   default resolver calls `Lwt_unix.getservbyname "http"` — a worker-pool
   job and an /etc/services read — once per request; `Resolver_lwt_unix.
   static_service` (Uri_services, pure OCaml) eliminates it. This of course
   helps the classic core too.
4. **The waiter-leak fix** (`856e73f18`, found by the §6 realistic suite):
   conduit's per-connection `pick` was the leak's exact pattern; with
   removable waiters the effect core stopped accumulating garbage across
   connections and now leads the classic core in **all four** configurations
   of this benchmark.

Also tried and **rejected by measurement**: routing close(2) through the ring
(IORING_OP_CLOSE) — the worker pool performs closes on another core, in
parallel with the event loop, and the ring version measured slower (the
negative result is recorded in a comment in lwt_unix). The remaining gap to
cohttp-eio is the client-side socket setup (2 fcntl per connection — needs
IORING_OP_SOCKET or a SOCK_NONBLOCK socket stub, <1 %) and the cohttp-lwt
stack itself (an `Lwt_io` buffered channel pair per connection, parsing). A
keep-alive workload amortizes the per-connection costs away. (The POC's
higher "native" bar was cohttp's *codecs only* on a hand-written backend, not
a usable stack — see the old report.)


## 6. Realistic HTTP benchmarks — replicated from existing suites

Two existing methodologies were reproduced as faithfully as possible
(server sources taken verbatim from the upstream repositories, marked
deviations only), with an external load generator (wrk2, built from source)
over real TCP — no in-process client:

- **[ocaml-multicore/retro-httpaf-bench](https://github.com/ocaml-multicore/retro-httpaf-bench)**:
  `GET /` with a fixed ~2 KB body (and an `Lwt.pause` per request in the
  cohttp-lwt server, as upstream), wrk2 at *fixed rates* with latency
  percentiles (their `json.lua`), scaled to one laptop core
  (`-t 4 -c 100 -d 20s`, rates 5k/10k/20k; upstream uses `-t 24 -c 1000` up
  to 400k on server hardware).
- **[robur-coop/httpcats bench protocol](https://github.com/robur-coop/httpcats/tree/main/bench)**:
  `GET /plaintext` ("Hello, World!"), wrk at saturation, repeated runs.
  Their Miou server (`smiou.ml`) is reproduced verbatim, run with
  `DOMAINS=1` for a single-core comparison.

Servers: cohttp-lwt-unix (retro's, classic and effect cores × libev and
io_uring — `conf-libev` is now installed, so the libev rows are real libev),
cohttp-eio (retro's, debug logging off), httpcats/Miou (theirs). Sources and
runner in [http/](http/).

**This suite found a real bug.** Its first pass (2026-06-12 morning) showed
the effect core with a catastrophic latency tail (p99 36–120 ms at 20 k req/s
vs classic's 18–20 ms) and −12 % saturation throughput — neither visible in
any in-process micro-benchmark above. Root-causing it (perf, callgrind, olly,
GC counters, and finally `live_words` sampled after `Gc.full_major` *under
load*) ended at a genuine **memory leak**: the effect core's waiter lists had
no removal mechanism — `Lwt.choose`/`pick` added a waiter to *every* promise
of their list and never removed the losers' when one resolved. A long-lived
promise repeatedly passed to `pick` (as conduit does, once per connection,
against the server's shutdown promise) accumulated dead waiters without
bound: live heap grew ~2.2 M words/s, linear, unbounded; the ballooning heap
made major-GC marking ~4× classic's (`do_some_marking` 8.5 % vs 2.3 % of
self-time, max GC pause 62 ms vs 1.7 ms) — the tail and the throughput gap
were both symptoms. Classic Lwt avoids exactly this with its
explicitly-removable callbacks ("added mainly by `Lwt.choose`"); the same
mechanism is now in the effect core
([`856e73f18`](https://github.com/ocsigen/lwt/commit/856e73f18): a shared-cell
waiter that detaches from the still-pending promises when it first fires —
`choose`/`pick`/`nchoose`/`nchoose_split`/`npick` and the
`protected`/`wrap_in_cancelable` mirrors), with the whole historical suite
still green. After the fix, the effect core's live set is flat under load and
its max GC pause (1.0 ms) is the best of the table.

Numbers **with the fix** (strictly interleaved, ≥2 rounds per cell, medians
for latency, means for throughput; the cohttp-eio and httpcats rows are from
the same day's earlier window):

| config | saturation (req/s, /plaintext) | p99 @5k | p99 @10k | p99 @20k |
|---|---|---|---|---|
| cohttp-eio | **68–82k** | **4.0 ms** | **4.6 ms** | 8.5 ms |
| Lwt classic, io_uring | 45.0k | 5.9 ms | 10.6 ms | 13.1 ms |
| Lwt effect core, io_uring | 43.1k (−4.3 %) | 5.5 ms | 11.6 ms | 17.3 ms |
| Lwt classic, libev | 35.5k | 4.9 ms | 9.5 ms | 16.4 ms |
| Lwt effect core, libev | 35.0k (−1.4 %) | 6.2 ms | 11.4 ms | 18.5 ms |
| httpcats (Miou, 1 domain) | 32.6k | 8.1 ms | 7.8 ms | **5.2 ms** |

Findings:

1. **The "tail-latency problem" is gone with the leak fix** — the two cores
   are at latency parity at every rate on both engines (in a dedicated
   interleaved 20 k A/B, median p99 came out 16.99 ms effect vs 17.05 ms
   classic). What remained of the original 36–120 ms after the fix was
   measurement: this laptop reaches ~85 °C after ~12 min of continuous
   benching and the `powersave` governor then throws 100–700 ms p99 spikes at
   *whichever* server runs last — classic included. Cool the machine between
   long suites and interleave, or distrust the last runs.
2. **The saturation gap narrowed from ~12 % to −4.3 % (io_uring) / −1.4 %
   (libev)** — the residual is near this machine's noise floor (the effect
   core won individual rounds of both metrics).
3. The transparent io_uring engine is worth **+27 %** to classic Lwt at
   saturation (35.5k → 45.0k) — its largest measured win, on unchanged code.
4. httpcats/Miou has the most *stable* latency of the table (p99 5–8 ms at
   every rate) at modest throughput — consistent with its bench report's
   claims about scheduler fairness; cohttp-eio dominates this single-core
   table on both axes. **Read that dominance for what it is: a comparison of
   HTTP *stacks*, not of scheduler cores.** cohttp-eio is a recent, lean
   rewrite; cohttp-lwt-unix carries conduit, a buffered `Lwt_io` channel
   pair per connection and an older protocol stack. Like-for-like — the same
   code on the two Lwt cores (§1–5), or raw I/O against Eio (echo, pingpong)
   — the effect core ties or beats Eio. The stack gap is cohttp-lwt's to
   close, and it shrank to ~5–9 % with the levers of §5.
5. The leak matters beyond benchmarks: any long-running server doing a
   `choose`/`pick` per request or connection against a long-lived promise
   would have leaked on the pre-fix effect core. **A realistic,
   external-load, minutes-long suite belongs in the methodology** — no
   in-process micro-benchmark surfaced it.

## Comparing with the POC

The POC configurations were **re-run during this campaign** (same machine
window) and reproduce their report almost exactly — POC scheduling 59 ns
(report: 52), POC echo Compat/ring 94.2k (94k), direct/ring 108k (107k) — so
the two reports are directly comparable. Where the POC bars are still ahead,
the cause is identified and none of it is the effect core itself:

| POC bar | today's equivalent | gap | cause |
|---|---|---|---|
| scheduling 52–59 ns (direct yield on the scheduler) | `Lwt_direct` 130 ns | ~2.2× | `Lwt_direct`'s task queue + `Lwt_main` hook indirection — re-plumb it onto the core's run queue (`Lwt.Private` hooks) |
| echo 108k (direct + private ring) | 95–96k (transparent engine) | ~12 % | direct style + completion I/O without the `Lwt_unix` layer — a semantics/API trade the drop-in declines |
| echo 94.2k (`Compat` + private ring) | 95–96k | none | the transparent engine matches the POC's private ring |

## Take-aways

1. **No regression — honestly accounted.** With a sound A/B protocol (and
   the §6 waiter-leak fix) the effect core is at parity or ahead of the
   classic core on *every* workload measured: ~2× on resolved bind, ~10 % on
   suspended bind through the full main loop (the once-claimed 14.7× was an
   artifact of an I/O-starvation conformance bug, since fixed — see §1),
   parity to ~8 % on the pause storm, tie on echo/pingpong, +7 % on cohttp,
   latency parity and −4.3 %/−1.4 % saturation (≈ noise) on the realistic
   HTTP suite.
2. **Unchanged Lwt code on io_uring is at Eio level** on raw-I/O workloads
   (echo three-way statistical tie, pingpong tie from 16 KB up), and
   **direct style (`Lwt_direct`, slimmed onto the core scheduler) is faster
   than Eio on scheduling** (69–76 vs 83–93 ns/yield, 16 vs 40 words).
3. cohttp-lwt is within **~5–9 %** of cohttp-eio under a clean A/B, mostly
   explained by the **connection-lifecycle syscalls** of the
   new-connection-per-request model: strace shows ~13 syscalls per request
   on the Lwt side (`socket`, 2×`fcntl`, 2×`setsockopt`,
   `connect`+`getsockopt`, `accept`, ~2.7×`close`) where eio_linux uses
   uring-native socket ops. The I/O itself is already optimally batched
   (fewer `io_uring_enter` than Eio). Closing this needs multishot accept /
   `socket`/`close` ops in ocaml-uring (only `close` is exposed today) — or
   simply a keep-alive workload, which amortizes the setup away.
4. **Protocol matters**: non-interleaved passes under varying load produced
   phantom regressions of 10–20 %, and thermal throttling produces phantom
   tail-latency disasters on whichever server runs last. Per-core binaries,
   alternated in the same window, on a cooled machine, removed them entirely.
   (Also: never `taskset` a uring benchmark to one core — the kernel io-wq
   workers inherit the affinity mask; and `strace -f` hangs on a uring
   server.)
5. **Realistic, external-load, minutes-long benchmarks are part of
   correctness testing**: the §6 suite caught an unbounded waiter leak
   (`choose`/`pick` against a long-lived promise) that 1200+ unit tests and
   every in-process micro-benchmark missed.

## Reproducing

```sh
# Switch with eio_main, miou, cohttp-eio, cohttp-lwt-unix installed.

# Workspace benchmarks (scheduling, bind, pingpong, echo): the Lwt core is
# the vendor/lwt symlink. Build one binary per core, SAVE both, then run
# them alternating:
ln -sfn /path/to/lwt-checkout-of-branch vendor/lwt   # lwt-uring | lwt-effects-core
dune build --profile release scheduling/bench.exe ... && cp _build/.../bench.exe /tmp/...
BENCH_CORE=classic ./saved-classic.exe ; BENCH_CORE=effects ./saved-effects.exe ; repeat

# cohttp: a separate project (cohttp/), built against the OPAM switch's lwt —
# build under each pin (opam pin lwt "...#branch"), save both binaries,
# alternate runs the same way. Use --root=. so the vendored lwt is ignored.

# Realistic HTTP suite (http/): also built against the OPAM lwt (move the
# vendor/lwt symlink aside while building, it clashes with the opam lwt via
# logs.lwt). Build under each pin, save the binaries
# (http/bin/server_lwt_{classic,effects}.exe), then bench with wrk2:
http/ab.sh 3 http/bin/server_lwt_effects.exe        # interleaved latency A/B
# (http/run.sh is the upstream-faithful runner but measures SEQUENTIALLY —
# fine for absolute numbers, do not use it for core-vs-core comparisons.)
# The server has a /gc route (Gc.full_major; reports live_words): sample it
# under load to check for leaks — a flat live_words is the pass criterion.
```

Pure-CPU benchmarks pinned with `taskset` (min of runs); I/O benchmarks
unpinned (pinning starves io_uring's kernel workers, which inherit the
affinity mask). Cool the machine between long suites (this laptop throttles
at ~85 °C after ~12 min of benching). Raw outputs in `results/`
(`retro2-*`/`plain2-*` are the post-fix interleaved runs).

Machine: Intel i7-9750H (laptop), Linux 6.17, OCaml 5.4.0 (no flambda),
libev for the epoll rows, `uring` 2.7.0 / `eio_linux` 1.3 / `miou` 0.6,
cohttp 6.2.1.
