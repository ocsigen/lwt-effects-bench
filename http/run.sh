#!/bin/bash
# Realistic HTTP benchmark runner, replicating two existing methodologies:
# - ocaml-multicore/retro-httpaf-bench: GET / (2 KB body), wrk2 at fixed
#   rates with latency percentiles (their json.lua), scaled to one laptop
#   core: -t 4 -c 100, rates 5k/10k/20k, 20 s (upstream: -t 24 -c 1000,
#   rates up to 400k, 60 s).
# - robur-coop/httpcats bench protocol: GET /plaintext ("Hello, World!"),
#   wrk throughput at saturation, several runs (upstream: -d 120 s x3).
#
# Usage: ./run.sh <label> <server-binary> [server args]
# The server is started on :18960, benched, stopped.
set -u
WRK=${WRK:-/home/balat/temp/wrk2/wrk}
PORT=18960
LABEL=$1; shift
BIN=$1; shift
OUT=results
mkdir -p $OUT

run_server() { "$BIN" -p $PORT "$@" & SRV=$!; sleep 1; }
stop_server() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; sleep 0.3; }

echo "=== $LABEL: retro protocol (GET /, 2KB, fixed-rate latency)"
for R in 5000 10000 20000; do
  run_server "$@"
  $WRK -t 4 -c 100 -d 20s -L -R $R -s json.lua http://127.0.0.1:$PORT/ \
    > $OUT/retro-$LABEL-R$R.txt 2>&1
  stop_server
  grep -E "requests_per_sec" $OUT/retro-$LABEL-R$R.txt | head -1
  python3 - "$OUT/retro-$LABEL-R$R.txt" <<'PY'
import json, sys, re
t = open(sys.argv[1]).read()
m = re.search(r"JSON Output:\n(\{.*\})", t, re.S)
if m:
    d = json.loads(m.group(1))
    lat = {x["percentile"]: x["latency_in_microseconds"] for x in d["latency_distribution"]}
    print(f"  p50={lat[50]/1000:.2f}ms p99={lat[99]/1000:.2f}ms p99.9={lat[99.9]/1000:.2f}ms max={lat[100]/1000:.2f}ms")
PY
done

echo "=== $LABEL: httpcats protocol (GET /plaintext, saturation x2)"
for i in 1 2; do
  run_server "$@"
  $WRK -t 4 -c 64 -d 20s -R 2000000 http://127.0.0.1:$PORT/plaintext \
    > $OUT/plain-$LABEL-run$i.txt 2>&1
  stop_server
  grep -E "Requests/sec" $OUT/plain-$LABEL-run$i.txt
done
