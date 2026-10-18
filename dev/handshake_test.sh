#!/bin/bash
# Serial pre-login handshake probe against the sandboxed TopSAP engine.
# Each step: report engine liveness before, run one command, report liveness after.
B=$HOME/topsap/bin
R=$HOME/topsap/run
REQ=$HOME/topsap/req
TAIL=${TAIL:-3}

alive() {
  local p; p=$(cat "$R/engine.pid" 2>/dev/null)
  [ -n "$p" ] || { echo "no-pidfile"; return 1; }
  kill -0 "$p" 2>/dev/null || { echo "pid $p gone"; return 1; }
  if grep -qi topsec "/proc/$p/maps" 2>/dev/null; then echo "pid $p alive:topsec"; else echo "pid $p alive:NO-topsec"; return 1; fi
}

step() {
  local name=$1 json=$2
  echo
  echo "################ STEP $name ################"
  echo "before: $(alive)"
  echo "---- output ----"
  "$B/topsap" run "$B/svdbg -t $TAIL @$json" 2>&1
  echo "---- rc=$? ----"
  echo "after : $(alive)"
}

echo "=== engine.log tail before ==="
tail -5 "$R/engine.log" 2>/dev/null
echo

step 1_query    "$REQ/q.json"
step 2_checkline "$REQ/cl.json"
step 3_authparam "$REQ/ap.json"
step 4_login    "$REQ/lg.json"
step 5_query_again "$REQ/q.json"

echo
echo "=== engine.log tail after ==="
tail -20 "$R/engine.log" 2>/dev/null
