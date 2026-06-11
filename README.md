# Lwt on effects — the in-place core swap, benchmarked

**2026-06-11.** [Lwt](https://github.com/ocsigen/lwt)'s core has been
reimplemented over OCaml 5 effects, **in place**: `src/core/lwt.ml` on the
[`lwt-effects-core` branch](https://github.com/ocsigen/lwt/tree/lwt-effects-core)
is the effect engine, behind the historical `lwt.mli` (unchanged but for three
scheduler hooks under `Lwt.Private`). It is a true drop-in: the **whole
historical test suite passes natively** (`test/core` 705, `test/unix` 233, the
ppx, `Lwt_react`, `Lwt_direct`, `lwt_uring` suites), and the unmodified
ecosystem recompiles and runs — cohttp-lwt-unix, ocsigenserver, Eliom,
Ocsigen Start.

This README is the benchmark report for that swap. The earlier
proof-of-concept report (separate `lwt_effects` package, two bind flavours,
hand-written cohttp backend) is preserved unchanged in
**[README-2026-06-poc.md](README-2026-06-poc.md)** for comparison; the code of
its configurations lives in this repository's git history.

> ⚠️ Same caveats as the POC report: micro-benchmarks, one (laptop) machine,
> loopback I/O, real run-to-run variance. Treat differences under ~10 % as
> noise; the **ratios and rankings** are the point, not the absolute numbers.

## What is being compared

The drop-in property makes the methodology pleasantly simple: **every Lwt
configuration below is the same benchmark binary, built from the same
public-API-only source** — what changes is which lwt is vendored:

| label | vendored lwt |
|---|---|
| `classic` | the [`lwt-uring` branch](https://github.com/ocsigen/lwt/tree/lwt-uring): the historical core + the mergeable io_uring engine |
| `effects` | the [`lwt-effects-core` branch](https://github.com/ocsigen/lwt/tree/lwt-effects-core): the effect-based core + the same io_uring engine |

Both branches carry the same transparent io_uring engine (`Lwt_uring.set ()`),
so the io_uring contribution and the core contribution are measured
independently, on both cores. **Eio** (`eio_main` 1.3, io_uring via
`eio_linux`) and **Miou** (0.6, `miou.unix`) are the external references.

## Results

### 1. Monadic bind — the headline

![bind](charts/swap-bind.svg)

| chain of binds (ns/op, words/op) | classic core | effect core |
|---|---|---|
| resolved (`bind (return v) f`) | 15.5 / 25 | **8.5 / 9** |
| suspended (`bind (pause ()) f`) | 1699.8 / 88 | **118.2 / 61** (~14×) |

The historical pending `bind` builds a promise, a callback, and proxy
bookkeeping; the effect core allocates one lean promise + callback and runs on
a ring-buffer scheduler. This is the cost of *every* `>>=` in every Lwt
program. The POC measured the same ~15× with its `mbind`
([old report](README-2026-06-poc.md#2-monadic-bind-on-a-pending-promise)); the
swap delivers it to unchanged code.

Two properties the microbenchmark numbers don't show:

- **Tail-recursive bind loops are O(1) in live memory** on both cores — but
  for different reasons. The effect core *reverse-merges* a pending bind's
  continuation promise into the anchored result (measured: flat at ~5.2k live
  words over a 2-million-step `pause () >>= loop`, slightly *below* the
  classic core). The first effect-core design retained ~21 words/step; the
  Lwt test suite does not catch this, only a long-running-loop probe did.
- **Lwt's semantics are preserved**, including the resolution loop
  (`wakeup_later` deferral), LIFO callback ordering, the full cancellation
  model, `Exception_filter` — each pinned down by Lwt's own 705-test core
  suite, plus the ppx and `Lwt_react` suites, running unchanged.

### 2. Scheduling (no I/O)

![scheduling](charts/swap-scheduling.svg)

| 1000 fibers × 1000 yields | ns/yield | words/yield |
|---|---|---|
| Eio | **119.5** | 40 |
| Lwt_direct (effect core) | 195.8 | **18** |
| Lwt_direct (classic core) | 199.6 | 18 |
| Lwt (classic core, `pause`) | 332.8 | 67 |
| Lwt (effect core, `pause`) | 407.2 | 61 |
| Miou | 534.1 | 67 |

Two honest observations. First, the monadic `pause`-storm is the one workload
where the effect core is *slower* than the classic one (~20 % here; parity at
moderate concurrency, worse at extreme fan-out) — the POC's 4.7× scheduling
win belonged to its *direct-style* effect `yield`, which the drop-in core
deliberately does not make the default. Second, that direct style is still
available — `Lwt_direct` runs unchanged on both cores at ~196 ns/yield with
the lowest allocation of the whole table (18 words/yield), between Eio and the
monadic rows.

(The campaign found and fixed a real bug here: on the effect core,
`Lwt_main.run` could block in the engine while `Lwt_direct`'s hook-pumped
tasks were ready, freezing a yield storm for ~60 s — the libev wait cap.
`Lwt_main` now refuses to block when the scheduler has ready work.)

### 3. Ping-pong latency (socketpair, payload sweep)

![pingpong](charts/swap-pingpong.svg)

µs per round-trip, min of 3 runs ("bigarray" = the `Lwt_bytes`/`Lwt_io` path):

| config | 1 B | 64 B | 1 KB | 16 KB | 256 KB |
|---|---|---|---|---|---|
| Lwt bytes (classic, epoll) | 10.8 | 11.1 | 11.4 | 14.7 | 107.6 |
| Lwt bytes (effects, epoll) | 11.6 | 11.8 | 11.9 | 16.3 | 116.4 |
| Lwt bigarray (classic, io_uring) | 7.8 | 7.9 | 8.4 | 12.5 | 88.3 |
| Lwt bigarray (effects, io_uring) | 8.1 | 8.2 | 8.5 | **11.6** | **84.9** |
| Eio (io_uring) | **7.9** | **7.6** | **7.8** | 12.0 | 86.7 |
| Miou | 27.4 | 26.0 | 26.1 | 30.8 | 194.6 |

Syscall-bound latency: the two cores are within ~5–8 % of each other on epoll
(classic slightly ahead), and **the unchanged Lwt code on io_uring is on par
with Eio at every size** — fastest of the table at 16 KB and 256 KB on the
effect core. The known caveat from the io_uring work still holds: the *bytes*
API (`Lwt_unix.read/write`) pays a copy per call under io_uring and regresses
at large payloads (443–509 µs at 256 KB); the bigarray path — what `Lwt_io`
and everything built on it actually uses — is copy-free.

### 4. Echo TCP — 100 concurrent connections

![echo](charts/swap-echo.svg)

| config | round-trips/s |
|---|---|
| Eio (io_uring) | **56 181** |
| Lwt (effect core, io_uring) | 51 279 |
| Lwt (classic core, io_uring) | 49 914 |
| Lwt (classic core, epoll) | 43 967 |
| Lwt (effect core, epoll) | 43 330 |
| Miou | 17 205 |

I/O under concurrency: the cores are at parity (the syscalls dominate), the
io_uring engine is worth ~+15 %, and unchanged Lwt code lands within ~10 % of
Eio.

### 5. cohttp — an unmodified, real HTTP stack

![cohttp](charts/swap-cohttp.svg)

The same `cohttp-lwt-unix` 6.2.1, **untouched**, recompiled against each core
(opam pin), `Client.get` with a new connection per request:

| config | req/s |
|---|---|
| cohttp-eio | **7 935** |
| cohttp-lwt (effect core, io_uring) | 5 864 |
| cohttp-lwt (classic core, io_uring) | 4 999 |
| cohttp-lwt (classic core, epoll) | 4 829 |
| cohttp-lwt (effect core, epoll) | 4 692 |

This is the chart to put next to the POC's
[cohttp section](README-2026-06-poc.md#5-cohttp--a-real-http-stack): there,
running unmodified cohttp-lwt *under* the effect scheduler via interop gave
**compatibility but zero speed-up** (≈5.6k on both bars), because the Lwt code
still executed on the classic core. With the in-place swap the unmodified
library actually runs *on* the effect core, and the best Lwt configuration
(effect core + io_uring) is **~+21 % over the classic baseline** — without the
POC's hand-written native backend (whose codecs-only bar reached higher, but
was not a usable stack). The remaining gap to cohttp-eio is mostly the
new-connection-per-request model (connection setup, where cohttp-lwt's client
is heavier) — with HTTP keep-alive the io_uring delta grows (see the
`lwt-uring` work: ~+30 % on the `Lwt_io` server path).

## Take-aways

1. **The drop-in works.** One `opam pin`: the whole historical test suite, the
   ppx, `Lwt_react`, `Lwt_direct`, cohttp, ocsigenserver/Eliom run unchanged.
2. **The bind machinery — Lwt's per-`>>=` cost — is ~14× cheaper** (suspended)
   and ~2× cheaper (resolved), with 2–3× fewer allocations, while preserving
   Lwt's semantics and keeping bind loops O(1) in memory.
3. **I/O-bound workloads are at parity on epoll and on par with Eio on
   io_uring**, the engine being worth ~15–25 % by itself on real paths
   (`Lwt_io`/cohttp).
4. The one regression is the extreme monadic `pause`-fan-out microbenchmark
   (~20 %); the direct-style alternative (`Lwt_direct`, unchanged) is ~2×
   faster than either core's monadic pause and allocates 3× less.

## Reproducing

```sh
# Switch with eio_main, miou, cohttp-eio, cohttp-lwt-unix installed
# (here: the lwt-uring-demo opam switch).

# Workspace benchmarks (scheduling, bind, pingpong, echo): the Lwt core is
# the vendor/lwt symlink — point it at the branch you want to measure.
ln -sfn /path/to/lwt-checkout-of-branch vendor/lwt   # lwt-uring | lwt-effects-core
dune build --profile release scheduling/bench.exe bind/bench.exe \
  pingpong/bench.exe echo/bench.exe
BENCH_CORE=classic ./_build/default/scheduling/bench.exe   # label accordingly

# cohttp benchmark: a separate project (cohttp/), built against the OPAM
# switch's lwt — pin lwt (and lwt_uring) to the branch to measure:
opam pin lwt "git+https://github.com/ocsigen/lwt#lwt-effects-core" -y
cd cohttp && dune build --root=. --profile release ./bench.exe
BENCH_CORE=effects ./_build/default/bench.exe
```

Protocol used for the tables above: scheduling and bind (pure CPU) pinned to
one core with `taskset`, minimum of 5 runs; I/O benchmarks unpinned (pinning
starves the io_uring kernel workers, which inherit the affinity mask),
minimum/maximum of 3 runs. Raw outputs are in `results/`.

Machine: Intel i7-9750H (laptop), Linux 6.17, OCaml 5.4.0 (no flambda),
libev backend for epoll rows, `uring` 2.7.0 / `eio_linux` 1.3 / `miou` 0.6,
cohttp 6.2.1. Versions and methodology details for the POC columns:
[README-2026-06-poc.md](README-2026-06-poc.md).
