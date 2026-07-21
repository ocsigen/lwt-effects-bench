#!/bin/bash
# bench-all.sh - build and run the full benchmark suite of this repository,
# reproducing the interleaved protocol of the README on any machine.
#
# What it does:
#   1. BUILD  one binary per Lwt core (classic / effects / lean) for the
#      workspace micro-benchmarks (vendor/lwt symlink flips + dune clean),
#      and for the opam-based benchmarks (cohttp in-process, http servers)
#      via opam pins. Binaries are saved under $BIN_DIR/<core>/.
#   2. RUN    every suite with the cores interleaved in the same windows:
#      bind, scheduling (pinned); ping-pong, echo (unpinned); cohttp
#      in-process; wrk2 suites (saturation + fixed-rate p99, io_uring and
#      libev) for cohttp and httpun; the reference servers (cohttp-eio,
#      httpcats, httpun-eio) in the same windows; a /gc live-set check; and
#      optionally olly gc-stats.
#   3. WRITE  raw outputs under $RESULTS_DIR/<date>/.
#
# Requirements (see the README "Reproducing" section):
#   - an opam switch (>= OCaml 5.3 to build all three cores; the lean core
#     alone also builds on >= 4.14) with: dune cppo dune-configurator
#     ocplib-endian conf-libev react ppxlib eio_main miou cohttp-lwt-unix
#     cohttp-eio httpcats httpun-lwt-unix httpun-eio runtime_events_tools
#   - uring pinned to the multishot-accept branch of ocaml-uring (see
#     README) for the io_uring rows;
#   - wrk2 built from source (giltene/wrk2), path in $WRK;
#   - a quiet machine. The script refuses to start a wrk suite while the
#     CPU is above $MAX_TEMP_C and waits for it to cool down.
#
# Protocol notes baked in (they were each learned the hard way):
#   - one binary per core, saved, runs ALTERNATED in the same window;
#   - dune clean between vendor/lwt flips, md5 check that binaries differ;
#   - taskset only for the pure-CPU suites; NEVER for io_uring servers;
#   - report ranges/medians over rounds, never a single run.
#
# Usage:
#   ./bench-all.sh [options]
#     --cores a,b,c    cores to benchmark   (default: classic,effects,lean)
#     --rounds N       interleaved rounds   (default: 3)
#     --only LIST      comma list among: bind,scheduling,pingpong,echo,
#                      cohttp,wrk,gc,olly   (default: all)
#     --skip-build     reuse the binaries already in $BIN_DIR
#     --bin-dir DIR    where binaries are saved (default: ./bin-cores)
#     --results DIR    output directory (default: results/full-<date>)
#     --quick          rounds=1 and shorter wrk runs (smoke test)

set -u
cd "$(dirname "$0")"

# ----------------------------------------------------------------- config
LWT_REPO=${LWT_REPO:-$(cd "$(readlink -f vendor/lwt 2>/dev/null || echo ../lwt)/.." 2>/dev/null && pwd)/lwt}
SWITCH=${SWITCH:-}            # empty = current opam switch
WRK=${WRK:-/home/balat/temp/wrk2/wrk}
MAX_TEMP_C=${MAX_TEMP_C:-55}
THERMAL=${THERMAL:-/sys/class/thermal/thermal_zone4/temp}
PIN_CPU=${PIN_CPU:-2}         # core for the pure-CPU suites
PORT=${PORT:-18990}
DUR=15s; P99_DUR=20s

declare -A BRANCH=( [classic]=lwt-uring [effects]=lwt-effects-core [lean]=lwt-lean-core )

CORES="classic,effects,lean"; ROUNDS=3; ONLY=all; SKIP_BUILD=0
BIN_DIR=./bin-cores; RESULTS_DIR=""
while [ $# -gt 0 ]; do case "$1" in
  --cores) CORES=$2; shift 2;;
  --rounds) ROUNDS=$2; shift 2;;
  --only) ONLY=$2; shift 2;;
  --skip-build) SKIP_BUILD=1; shift;;
  --bin-dir) BIN_DIR=$2; shift 2;;
  --results) RESULTS_DIR=$2; shift 2;;
  --quick) ROUNDS=1; DUR=5s; P99_DUR=5s; shift;;
  *) echo "unknown option: $1" >&2; exit 2;;
esac; done
IFS=, read -ra CORE_LIST <<< "$CORES"
RESULTS_DIR=${RESULTS_DIR:-results/full-$(date +%Y%m%d-%H%M)}
mkdir -p "$RESULTS_DIR" "$BIN_DIR"

OPAM () { if [ -n "$SWITCH" ]; then opam "$1" --switch "$SWITCH" "${@:2}"; else opam "$@"; fi; }
DUNE () { if [ -n "$SWITCH" ]; then opam exec --switch "$SWITCH" -- dune "$@"; else opam exec -- dune "$@"; fi; }

log () { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESULTS_DIR/log.txt"; }
want () { [ "$ONLY" = all ] || [[ ",$ONLY," == *",$1,"* ]]; }

wait_cool () {
  [ -r "$THERMAL" ] || return 0
  local t
  while t=$(cat "$THERMAL") && [ "$((t/1000))" -gt "$MAX_TEMP_C" ]; do
    log "CPU at $((t/1000))C > ${MAX_TEMP_C}C: cooling down 30s..."
    sleep 30
  done
}

# ------------------------------------------------------------------ build
build_all () {
  local core wt
  # workspace micro-benchmarks: vendor/lwt flip per core
  local vendor_orig; vendor_orig=$(readlink vendor/lwt)
  for core in "${CORE_LIST[@]}"; do
    wt=$(mktemp -d /tmp/lwt-wt-XXXX)
    log "build[$core]: worktree ${BRANCH[$core]} -> $wt"
    git -C "$LWT_REPO" worktree add --detach "$wt" "${BRANCH[$core]}" >/dev/null || exit 1
    ln -sfn "$wt" vendor/lwt
    DUNE clean
    DUNE build --profile release bind/bench.exe scheduling/bench.exe \
      pingpong/bench.exe echo/bench.exe || exit 1
    mkdir -p "$BIN_DIR/$core"
    local b; for b in bind scheduling pingpong echo; do
      cp "_build/default/$b/bench.exe" "$BIN_DIR/$core/$b.exe"
    done
    git -C "$LWT_REPO" worktree remove --force "$wt"
  done
  ln -sfn "$vendor_orig" vendor/lwt
  # opam-based benchmarks: pin dance per core (NO && between opam steps:
  # opam exits 31 on partial actions; always follow with --restore)
  local url="git+file://$LWT_REPO"
  for core in "${CORE_LIST[@]}"; do
    log "build[$core]: opam pin lwt/lwt_uring -> ${BRANCH[$core]}"
    OPAM pin -y lwt "$url#${BRANCH[$core]}" >/dev/null 2>&1
    OPAM pin -y lwt_uring "$url#${BRANCH[$core]}" >/dev/null 2>&1
    OPAM install -y --restore >/dev/null 2>&1
    ( cd cohttp && DUNE build --root=. --profile release ./bench.exe ) || exit 1
    cp cohttp/_build/default/bench.exe "$BIN_DIR/$core/cohttp.exe"
    ( cd http && DUNE build --root=. --profile release \
        ./server_cohttp_lwt.exe ./server_httpun_lwt.exe ) || exit 1
    cp http/_build/default/server_cohttp_lwt.exe "$BIN_DIR/$core/server_cohttp_lwt.exe"
    cp http/_build/default/server_httpun_lwt.exe "$BIN_DIR/$core/server_httpun_lwt.exe"
  done
  # reference servers (lwt-pin independent; built once)
  ( cd http && DUNE build --root=. --profile release \
      ./server_cohttp_eio.exe ./server_httpcats.exe ./server_httpun_eio.exe ) || exit 1
  local r; for r in server_cohttp_eio server_httpcats server_httpun_eio; do
    cp "http/_build/default/$r.exe" "$BIN_DIR/$r.exe"
  done
  # sanity: per-core binaries must differ (the stale-_build trap)
  if [ "${#CORE_LIST[@]}" -gt 1 ]; then
    local n; n=$(md5sum "$BIN_DIR"/*/bind.exe | awk '{print $1}' | sort -u | wc -l)
    [ "$n" -eq "${#CORE_LIST[@]}" ] || { log "FATAL: identical bind.exe across cores (stale _build?)"; exit 1; }
  fi
}

# -------------------------------------------------------------------- run
run_micro () { # suite, pinned?
  local suite=$1 pin=$2 core i cmd out="$RESULTS_DIR/$1.txt"
  for i in $(seq 1 "$ROUNDS"); do
    for core in "${CORE_LIST[@]}"; do
      wait_cool
      cmd=("$BIN_DIR/$core/$suite.exe")
      [ "$pin" = pin ] && cmd=(taskset -c "$PIN_CPU" "${cmd[@]}")
      log "run $suite round $i core $core"
      BENCH_CORE=$core "${cmd[@]}" >> "$out" 2>&1
    done
  done
}

serve_and_wrk () { # binary, args, rate, duration, path, tag
  local bin=$1 args=$2 rate=$3 dur=$4 upath=$5 tag=$6
  wait_cool
  $bin -p $PORT $args >/dev/null 2>&1 & local srv=$!
  sleep 1
  local out; out=$("$WRK" -t 4 -c 64 -d "$dur" -L -R "$rate" "http://127.0.0.1:$PORT$upath" 2>&1)
  kill $srv 2>/dev/null; wait $srv 2>/dev/null; sleep 0.5
  local rps p99
  rps=$(echo "$out" | awk '/^Requests\/sec/ {print $2}')
  p99=$(echo "$out" | awk '/^ 99.000%/ {print $2}')
  echo "$tag rps=$rps p99=$p99" | tee -a "$RESULTS_DIR/wrk.txt"
}

run_wrk_suites () {
  local i core engine flag
  for i in $(seq 1 "$ROUNDS"); do
    for engine in uring libev; do
      flag=""; [ "$engine" = uring ] && flag="-u"
      for core in "${CORE_LIST[@]}"; do
        serve_and_wrk "$BIN_DIR/$core/server_cohttp_lwt.exe" "$flag" 2000000 "$DUR" /plaintext "sat-cohttp $engine r$i $core"
      done
      for core in "${CORE_LIST[@]}"; do
        serve_and_wrk "$BIN_DIR/$core/server_httpun_lwt.exe" "$flag" 2000000 "$DUR" /plaintext "sat-httpun $engine r$i $core"
      done
      local rate; for rate in 5000 10000 20000; do
        for core in "${CORE_LIST[@]}"; do
          serve_and_wrk "$BIN_DIR/$core/server_cohttp_lwt.exe" "$flag" "$rate" "$P99_DUR" / "p99-cohttp $engine r$i rate$rate $core"
        done
      done
    done
    # reference stacks, same windows (their engines are their own)
    serve_and_wrk "$BIN_DIR/server_cohttp_eio.exe" "" 2000000 "$DUR" /plaintext "sat-REF cohttp-eio r$i"
    DOMAINS=1 serve_and_wrk "$BIN_DIR/server_httpcats.exe" "" 2000000 "$DUR" /plaintext "sat-REF httpcats r$i" || true
    serve_and_wrk "$BIN_DIR/server_httpun_eio.exe" "" 2000000 "$DUR" /plaintext "sat-REF httpun-eio r$i"
  done
}

run_gc_check () { # flat live_words under sustained load = no leak
  local core
  for core in "${CORE_LIST[@]}"; do
    wait_cool
    log "gc-check $core"
    "$BIN_DIR/$core/server_cohttp_lwt.exe" -p $PORT -u >/dev/null 2>&1 & local srv=$!
    sleep 1
    ( "$WRK" -t 2 -c 16 -d 32s -R 2000000 "http://127.0.0.1:$PORT/plaintext" >/dev/null 2>&1 & )
    local i; for i in 1 2 3 4 5 6; do
      { curl -s "http://127.0.0.1:$PORT/gc"; echo " ($core t=${i}x5s)"; } >> "$RESULTS_DIR/gc.txt"
      sleep 5
    done
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
  done
}

run_olly () { # GC share + pause profile at saturation (user-space tracing)
  command -v olly >/dev/null 2>&1 || OPAM exec -- olly --version >/dev/null 2>&1 || { log "olly not found: skip"; return 0; }
  local name bin args
  for spec in "cohttp-eio|$BIN_DIR/server_cohttp_eio.exe|" \
              "httpun-lean|$BIN_DIR/lean/server_httpun_lwt.exe|-u" \
              "cohttp-lean|$BIN_DIR/lean/server_cohttp_lwt.exe|-u"; do
    IFS='|' read -r name bin args <<< "$spec"
    [ -x "$bin" ] || continue
    wait_cool; log "olly $name"
    OPAM exec -- olly gc-stats "$bin -p $PORT $args" > "$RESULTS_DIR/olly-$name.txt" 2>&1 &
    sleep 2
    "$WRK" -t 4 -c 64 -d 30s -R 2000000 "http://127.0.0.1:$PORT/plaintext" 2>&1 \
      | awk -v n="$name" '/^Requests\/sec/ {print "olly", n, "rps="$2}' | tee -a "$RESULTS_DIR/wrk.txt"
    local pid; pid=$(pgrep -f "^$bin")
    ps -o times= -p $pid | awk -v n="$name" '{print "olly", n, "cpu_s="$1}' | tee -a "$RESULTS_DIR/wrk.txt"
    kill $pid 2>/dev/null; sleep 3
  done
}

# ------------------------------------------------------------------- main
log "cores=$CORES rounds=$ROUNDS only=$ONLY results=$RESULTS_DIR"
log "machine: $(uname -r), governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
[ "$SKIP_BUILD" = 1 ] || build_all
want bind        && run_micro bind pin
want scheduling  && run_micro scheduling pin
want pingpong    && run_micro pingpong nopin
want echo        && run_micro echo nopin
want cohttp      && run_micro cohttp nopin
want wrk         && run_wrk_suites
want gc          && run_gc_check
want olly        && run_olly
log "done. Raw outputs in $RESULTS_DIR/"
