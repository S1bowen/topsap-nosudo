#!/bin/bash
# Give the engine an *accepting* peer on 127.0.0.1:443 (inside the netns) and see
# whether get_auth_param still kills it, and what bytes it sends.
B=$HOME/topsap/bin; R=$HOME/topsap/run; REQ=$HOME/topsap/req
alive(){ local p; p=$(cat "$R/engine.pid" 2>/dev/null)
  { [ -n "$p" ] && kill -0 "$p" 2>/dev/null && grep -qi topsec "/proc/$p/maps" 2>/dev/null; } \
    && echo "alive pid $p" || echo "DEAD pid=${p:-none}"; }

echo "before get_auth_param : $(alive)"

echo "--- start fake peer on 127.0.0.1:443 inside netns ---"
"$B/topsap" run "rm -f $R/fake443.log; setsid socat -v -x TCP-LISTEN:443,reuseaddr,fork,backlog=8 SYSTEM:'sleep 25' >$R/fake443.log 2>&1 </dev/null & sleep 1; ss -ltn 2>/dev/null | grep ':443' || echo NO-LISTENER"

echo "--- get_auth_param ---"
"$B/topsap" run "$B/svdbg -t 8 @$REQ/ap.json"
echo "after  get_auth_param : $(alive)"

echo "--- get_auth_param again (second observation) ---"
"$B/topsap" run "$B/svdbg -t 8 @$REQ/ap.json"
echo "after  2nd attempt    : $(alive)"

echo "=== fake443.log ==="
head -c 6000 "$R/fake443.log" 2>/dev/null || echo "(no log)"
