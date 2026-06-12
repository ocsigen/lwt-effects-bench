#!/bin/bash
# Strict A/B: alternate classic and effects binaries in the same window.
# Usage: ./ab.sh <rounds> <effects-binary> [extra wrk note]
# Always uring (-u), R=20000, retro protocol.
set -u
DIR=/home/balat/prog/kroko/ocsigen/lwt-effects-bench/http
cd "$DIR"
WRK=${WRK:-/home/balat/temp/wrk2/wrk}
LUA="$DIR/json.lua"
PORT=18962
ROUNDS=${1:-3}
EFF=${2:-bin/server_lwt_effects.exe}
CLA=bin/server_lwt_classic.exe
R=20000

run_one() {
  local bin=$1
  "$bin" -p $PORT -u >/dev/null 2>&1 & local srv=$!
  sleep 1
  local out
  out=$("$WRK" -t 4 -c 100 -d 20s -L -R $R -s "$LUA" http://127.0.0.1:$PORT/ 2>&1)
  kill $srv 2>/dev/null; wait $srv 2>/dev/null; sleep 0.5
  echo "$out" > /tmp/ab_out.txt
  python3 - /tmp/ab_out.txt <<'PY'
import json,sys,re
t=open(sys.argv[1]).read()
m=re.search(r"JSON Output:\n(\{.*\})",t,re.S)
rps=re.search(r"requests_per_sec[\"']?\s*[:=]?\s*([0-9.]+)",t)
if m:
 d=json.loads(m.group(1)); lat={x["percentile"]:x["latency_in_microseconds"] for x in d["latency_distribution"]}
 r=d.get("requests_per_sec","?")
 print(f"    rps={r:>9} p50={lat[50]/1000:6.2f}ms p99={lat[99]/1000:7.2f}ms p99.9={lat[99.9]/1000:7.2f}ms max={lat[100]/1000:7.2f}ms")
else:
 print("    (no JSON output)"); print(t[-300:])
PY
}

for i in $(seq 1 $ROUNDS); do
  echo "round $i  classic:"; run_one "$CLA"
  echo "round $i  effects:"; run_one "$EFF"
done
