# cohttp benchmarks

cohttp running on the three runtimes:

- `bench.ml` — `cohttp-lwt-unix` (under `Lwt_main`, and under `Lwt_effects` via
  the Lwt interop) vs `cohttp-eio`, using `Client.get` (new connection per
  request).
- `bench_native.ml` — cohttp running **natively on `Lwt_effects`** (epoll and
  io_uring), via the `Le_cohttp` backend (`le_cohttp.ml`, an implementation of
  `Cohttp.S.IO` with monadic buffered channels). Keep-alive and
  new-connection-per-request variants.

This is a **separate dune project** (own `dune-project`) because it needs an
opam switch where `lwt` is 6.x and `lwt_effects`, `lwt_effects_uring`,
`cohttp-lwt-unix`, `cohttp-eio`, `eio_main` are installed — e.g. an Ocsigen
monorepo switch with `lwt` pinned to the `lwt-effects-poc` branch. (The sibling
benchmarks build `lwt`/`lwt_effects` from a vendored source tree instead; the
two setups don't mix in one project.)

```sh
eval $(opam env --switch=/path/to/such/switch --set-switch)
dune exec ./bench_native.exe        # cohttp natively on Lwt_effects (epoll+uring)
dune exec ./bench.exe               # cohttp-lwt / interop / cohttp-eio
```
