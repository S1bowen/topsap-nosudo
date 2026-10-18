#!/bin/bash
B=$HOME/topsap/bin; R=$HOME/topsap/run; REQ=$HOME/topsap/req
alive(){ local p; p=$(cat "$R/engine.pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "alive pid $p ($(readlink /proc/$p/exe 2>/dev/null))"; else echo "DEAD pid=${p:-none}"; fi; }

echo "### restart engine under strace ###"
"$B/topsap" down >/dev/null 2>&1; sleep 1
TOPSAP_STRACE=1 "$B/topsap" up 2>&1 | tail -2
sleep 3
echo "state: $(alive)"
echo
echo "### baseline: query_status ###"
"$B/topsap" run "$B/svdbg -t 3 @$REQ/q.json" 2>&1 | tail -4
echo "state: $(alive)"
echo
echo "### get_auth_param (expect death) ###"
"$B/topsap" run "$B/svdbg -t 6 @$REQ/ap.json" 2>&1 | tail -6
echo "state: $(alive)"
sleep 2
echo
echo "=== library log /tmp/TopSAP_ELE.log (tail 40) ==="
tail -40 /tmp/TopSAP_ELE.log 2>/dev/null || echo "(no /tmp/TopSAP_ELE.log)"
ls -l /tmp/TopSAP_ELE* 2>/dev/null
echo
echo "=== engine.strace tail 60 ==="
tail -60 "$R/engine.strace" 2>/dev/null || echo "(no strace)"
