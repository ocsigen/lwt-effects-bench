# cohttp benchmark

The same, unmodified `cohttp-lwt-unix` (server + clients in one process,
`Client.get`, new connection per request) on the Lwt core pinned in the opam
switch — the classic core or the effect-based one — plus a second pass under
the transparent io_uring engine (`Lwt_uring.set ()`), and `cohttp-eio` as the
external reference.

This is a **separate dune project** (own `dune-project`): unlike the sibling
benchmarks (which build lwt from the vendored source tree), it links the
*installed* `cohttp-lwt-unix`, so the Lwt core under test is the one the
switch's `lwt` is pinned to. Build it with `--root=.` so the parent
workspace's vendored lwt is not picked up:

```sh
opam pin lwt       "git+https://github.com/ocsigen/lwt#lwt-effects-core" -y
opam pin lwt_uring "git+https://github.com/ocsigen/lwt#lwt-effects-core" -y
dune build --root=. --profile release ./bench.exe
BENCH_CORE=effects ./_build/default/bench.exe
# then pin to #lwt-uring and rerun with BENCH_CORE=classic
```

The POC-era files (`bench_native.ml`, `le_cohttp.ml`: cohttp's codecs driven
natively by the separate `lwt_effects` scheduler) were removed when the core
swap subsumed that package; they remain in git history, and their results in
[../README-2026-06-poc.md](../README-2026-06-poc.md).
