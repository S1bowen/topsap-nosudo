#!/bin/bash
# vpnup.sh -- one-shot zero-privilege TopSAP login.
#
#   ~/topsap/bin/vpnup.sh                  # prompts for the password and the TOTP
#   TOPSAP_PWD=... ~/topsap/bin/vpnup.sh   # password from the environment
#
# Request shapes are taken from the shipped client (vone/pub/common/scripts/
# sv_init.js) and were verified against the real libtopsec_vpn.so:
#
#   get_auth_param -> login_by_pwd -> chk_sms(flag=otp) -> get_config_info -> query_status
#
# It always restarts the sandbox first, so the private-sysfs fix (without which
# libtopsec_vpn.so cannot see the tun device it creates) is guaranteed in place
# before the engine starts.
set -u
ROOT=${TOPSAP_ROOT:-$HOME/topsap}
cd "$ROOT" || exit 1

# Site settings come from $ROOT/topsap.env (see topsap.env.example) or from the
# environment.  Nothing site-specific is baked into this script.
[ -f "$ROOT/topsap.env" ] && . "$ROOT/topsap.env"

HOST=${TOPSAP_HOST:-}                 # gateway address, required
PORT=${TOPSAP_PORT:-443}              # gateway port
VPN_USER=${TOPSAP_USER:-}             # VPN account, required
TARGET=${TOPSAP_TARGET:-}             # optional: an address to probe after login
TEST_HOST=${TOPSAP_TEST_HOST:-}       # optional: an ssh alias to test after login
PROXY_PORT=${TOPSAP_PROXY_PORT:-18438}

say(){ printf '%s\n' "$*"; }
die(){ say "$*"; exit 1; }

[ -n "$HOST" ] || die "TOPSAP_HOST is not set (see topsap.env.example)"
[ -n "$VPN_USER" ] || die "TOPSAP_USER is not set (see topsap.env.example)"

# ------------------------------------------------------------------ engine I/O

extract(){  # $1 raw capture, $2 destination json
  python3 "$ROOT/bin/svjson.py" "$1" "$2"
}

send(){  # $1 label, $2 request json (relative), $3 output basename
  say ""
  say "=== $1 ==="
  bin/topsap run "svctl @$ROOT/$2" > "run/$3.raw" 2>&1
  extract "run/$3.raw" "run/$3.json"
  python3 - "run/$3.json" <<'PY'
import sys, json
try:
    d = json.loads(open(sys.argv[1]).read())
except Exception as e:
    print('  <unparsed>', e); raise SystemExit
for k in ('err_code', 'err_msg', 'msg', 'session_id', 'login_err_num', 'state_id',
          'tstate_id', 'vip', 'vip_mask', 'tunnel_type', 'terr_code', 'account_end'):
    if k in d and d[k] not in ('', None):
        print('  %-14s %r' % (k, d[k]))
open(sys.argv[1] + '.code', 'w').write(str(d.get('err_code')))
PY
}

code(){ cat "run/$1.json.code" 2>/dev/null; }

# ------------------------------------------------------------------------ run

umask 077

say "--- restarting the sandbox (fresh sysfs bound to our network namespace) ---"
bin/topsap up | sed 's/^/  /' || die "sandbox failed to start"
grep -E 'sysfs|passwd|overlay|lo up|ready' run/sandbox.log | sed 's/^/  /'

say ""
say "--- /sys/class/net as seen by the engine's namespace ---"
bin/topsap run 'ls /sys/class/net/' | sed 's/^/  /'

# Password sources, in order: $TOPSAP_PWD, $ROOT/.pwd (mode 600), interactive.
PW=${TOPSAP_PWD:-}
[ -z "$PW" ] && [ -f "$ROOT/.pwd" ] && PW=$(cat "$ROOT/.pwd")
if [ -z "$PW" ]; then
  printf 'password for %s@%s:%s: ' "$VPN_USER" "$HOST" "$PORT"
  read -rs PW; echo
fi
[ -n "$PW" ] || die "no password given"

say ""
say "=== get_auth_param ==="
printf '%s' "$PW" | python3 bin/svmk.py authparam "$HOST" "$PORT" "$VPN_USER" > run/auth.json \
  || die "could not build get_auth_param"
bin/topsap run "svctl @$ROOT/run/auth.json" > run/auth.raw 2>&1
extract run/auth.raw run/auth.json
python3 - run/auth.json <<'PY'
import sys, json
try:
    d = json.loads(open(sys.argv[1]).read())
except Exception as e:
    print('  <unparsed>', e); raise SystemExit
for k in ('vpn_version', 'twofactor', 'sms', 'pswd', 'cert', 'mtu', 'auth_port', 'data_port'):
    if k in d:
        print('  %-12s %r' % (k, d[k]))
PY

printf '%s' "$PW" | python3 bin/svmk.py login "$HOST" "$PORT" "$VPN_USER" run/auth.json > run/login.json \
  || die "could not build login_by_pwd"
send "login_by_pwd" run/login.json login
rc=$(code login)
case "$rc" in
  0)              say "  -> already authenticated";;
  -40190|-40192)  say "  -> 2FA required (Google Authenticator)";;
  *)              die "  -> login failed (err_code=$rc); check the password";;
esac

if [ "$rc" != "0" ]; then
  say ""
  say "Enter the CURRENT Google Authenticator code for $VPN_USER."
  say "It expires in ~30 s, so have the app open before you start typing."
  printf 'code: '
  read -r CODE
  [ -n "$CODE" ] || die "no code given"
  python3 bin/svmk.py otp "$CODE" run/auth.json > run/otp.json || die "could not build chk_sms"
  chmod 600 run/otp.json
  send "chk_sms flag=otp (2FA)" run/otp.json otp
  rc=$(code otp)
  if [ "$rc" != "0" ]; then
    say ""
    say "2FA rejected (err_code=$rc). If the code was simply too old, just run"
    say "this script again - nothing is broken."
    exit 1
  fi
fi

python3 bin/svmk.py raw '{"method":"get_config_info"}' > run/cfg.json
send "get_config_info" run/cfg.json cfg

python3 bin/svmk.py query_status > run/qs.json
send "query_status" run/qs.json qs

say ""
say "=== tunnel ==="
# query_statistics is what the shipped client polls after login (sv_init.js
# checkNaStatus: tstate_id 6 or 16 means up, once per second).  query_status
# reports tstate_id 0 on this gateway even while the tunnel is established, so
# it is not used for the verdict here.
# Keep the request in its own file: svctl reads the request from @FILE and the
# reply is extracted into run/stats.json, so reusing one path would make the
# second poll send the previous reply back to the engine.
python3 bin/svmk.py raw '{"method":"query_statistics"}' > run/stats.req.json
TS=
for i in $(seq 1 20); do
  bin/topsap run "svctl @$ROOT/run/stats.req.json" > run/stats.raw 2>&1
  extract run/stats.raw run/stats.json
  TS=$(python3 - <<'PY'
import json
try:
    print(json.load(open('run/stats.json')).get('tstate_id'))
except Exception:
    print('')
PY
)
  case "$TS" in 6|16) break;; esac
  sleep 1
done
python3 - run/stats.json <<'PY'
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for k in ('tstate_id', 'terr_code', 'vip', 'vip_mask', 'tunnel_duration',
          'send_bytes', 'recv_bytes'):
    if k in d:
        print('  %-16s %r' % (k, d[k]))
PY
case "$TS" in
  6|16) say "  -> tunnel ESTABLISHED (tstate_id=$TS)";;
  *)    say "  -> tunnel NOT established (tstate_id=${TS:-unknown})"
        say "  --- engine log tail ---"
        tail -n 20 run/engine.log | sed 's/^/  /';;
esac

# The engine creates tun0 and adds the ACL routes; make sure the assigned vip is
# actually on the interface before probing, because without a source address the
# kernel will not put any packet on tun0 at all.  Adding it here only touches
# the private network namespace, so it needs no privilege.
VIP=$(python3 - <<'PY'
import json
try:
    print(json.load(open('run/stats.json')).get('vip') or '')
except Exception:
    print('')
PY
)
case "$VIP" in
  ''|0.0.0.0) :;;
  *) if bin/topsap run "ip -4 -o addr show dev tun0 2>/dev/null | grep -qw '$VIP'"; then
       say "  tun0 carries $VIP"
     elif bin/topsap run "ip link show tun0" >/dev/null 2>&1; then
       say "  tun0 does NOT carry $VIP - adding it (inside the private netns)"
       bin/topsap run "ip addr add $VIP/32 dev tun0" 2>&1 | sed 's/^/  /'
     fi;;
esac
{ bin/topsap run 'ip -br addr show tun0 2>/dev/null; ip route 2>/dev/null'; } 2>/dev/null | sed 's/^/  /'

tunrx(){ bin/topsap run 'cat /sys/class/net/tun0/statistics/rx_bytes 2>/dev/null' 2>/dev/null | tr -dc '0-9'; }

if [ -n "$TARGET" ]; then
  # TOPSAP_TARGET is host or host:port.  Split it: when a port is given, probe
  # exactly that one; otherwise try ssh and telnet.
  PROBE_HOST=${TARGET%:*}
  PROBE_PORTS=${TARGET##*:}
  [ "$PROBE_HOST" = "$TARGET" ] && PROBE_PORTS="22 23"
  say ""
  say "=== reachability: $PROBE_HOST (port(s): $PROBE_PORTS) ==="
  R0=$(tunrx)
  bin/topsap run "for p in $PROBE_PORTS; do if timeout 8 bash -c \"exec 3<>/dev/tcp/$PROBE_HOST/\$p\" 2>/dev/null; then echo \"  $PROBE_HOST:\$p OPEN\"; else echo \"  $PROBE_HOST:\$p closed or filtered\"; fi; done" 2>/dev/null
  R1=$(tunrx)
  say "  tun0 rx_bytes: ${R0:-?} -> ${R1:-?}  (unchanged: nothing came back on tun0)"
fi

if [ -n "$TEST_HOST" ]; then
  say ""
  say "=== ssh test: $TEST_HOST ==="
  bin/topsap run "HOME='$HOME' ssh -o BatchMode=yes -o ConnectTimeout=60 -o StrictHostKeyChecking=accept-new '$TEST_HOST' 'hostname; id -un'" 2>&1 \
    | grep -vE 'Pseudo-terminal|Warning: Permanently added' | sed 's/^/  /'
fi

say ""
say "To use it:  ~/topsap/bin/topsap ssh <alias>          # interactive login,"
say "                                                     #   any host in ~/.ssh/config"
say "            ~/topsap/bin/topsap shell                # shell inside the tunnel"
say "            ~/topsap/bin/topsap proxy up             # lend this machine's proxy"
say "                                                     #   to the remote as :$PROXY_PORT"
say "            ~/topsap/bin/topsap pxcheck              # verify it from over there"
say "            ~/topsap/bin/topsap down                 # disconnect (also stops the proxy)"

# Optional: bring the reverse proxy up right away, so the remote side has it from
# the moment you log in.  TOPSAP_PROXY=up makes that the default for this run.
if [ "${TOPSAP_PROXY:-}" = up ]; then
  say ""
  say "=== proxy (TOPSAP_PROXY=up) ==="
  bin/topsap proxy up | sed 's/^/  /'
fi
