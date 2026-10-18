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
TSTATE=$(python3 - <<'PY'
import json
try:
    d = json.load(open('run/qs.json'))
except Exception:
    raise SystemExit
print('%s %s %s %s' % (d.get('tstate_id'), d.get('vip'), d.get('vip_mask'), d.get('state_id')))
PY
)
case "$TSTATE" in
  "6 "*) say "  tstate_id=6 - tunnel ESTABLISHED  ($TSTATE)";;
  *)     say "  tunnel not up  (tstate_id vip mask state_id = $TSTATE)"
         say "  --- engine log tail ---"
         tail -n 20 run/engine.log | sed 's/^/  /';;
esac
bin/topsap run 'ip -br addr 2>/dev/null | sed "s/^/  /"' 2>/dev/null
bin/topsap run 'ip route 2>/dev/null | sed "s/^/  /"' 2>/dev/null

if [ -n "$TARGET" ]; then
  say ""
  say "=== reachability: $TARGET ==="
  bin/topsap run "for p in 22 23; do if timeout 8 bash -c \"exec 3<>/dev/tcp/$TARGET/\$p\" 2>/dev/null; then echo \"  $TARGET:\$p OPEN\"; else echo \"  $TARGET:\$p closed\"; fi; done" 2>/dev/null
fi

if [ -n "$TEST_HOST" ]; then
  say ""
  say "=== ssh test: $TEST_HOST ==="
  bin/topsap run "HOME='$HOME' ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new '$TEST_HOST' 'hostname; id -un'" 2>&1 \
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
