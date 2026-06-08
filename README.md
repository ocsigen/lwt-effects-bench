# lwt-effects-bench

Comparative benchmarks for the effect-based Lwt scheduler POC
(`lwt_effects` / `lwt_effects_uring`, developed in the `lwt-effects-poc`
branch of the `lwt` repo) against classic Lwt, Eio and Miou.

## Layout

- `pingpong/` — ping-pong over a socketpair, payload-size sweep, five back ends.

## Building

`lwt_effects` and `lwt_effects_uring` are unreleased and live in the sibling
`lwt` checkout. They are built from source as a vendored directory:

```sh
ln -s ../../lwt vendor/lwt    # already created; points at the lwt checkout
dune build --profile release
```

Other dependencies (`eio`, `eio_main`, `miou`, `cohttp-eio`, `cohttp-lwt-unix`)
come from the opam switch. Linux only (io_uring).

## Running

```sh
dune exec --profile release pingpong/bench.exe
```
