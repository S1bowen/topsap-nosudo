#!/bin/bash
# twofa.sh [CODE]  -- submit the Google-Authenticator code and finish the login.
#
# Run this on the machine that holds the sandbox, so the 30-second window is
# under your control:
#
#     ~/topsap/bin/twofa.sh            # prompts, you type the code
#     ~/topsap/bin/twofa.sh 123456     # non-interactive
#
# Chain (all verified against the shipped client):
#     chk_sms flag=otp  ->  get_config_info  ->  query_status  ->  ssh test
set -u
ROOT=${TOPSAP_ROOT:-$HOME/topsap}
cd "$ROOT" || exit 1
[ -f "$ROOT/topsap.env" ] && . "$ROOT/topsap.env"

CODE="${1:-}"
if [ -z "$CODE" ]; then
  printf 'Google Authenticator code: '
  read -r CODE
fi
[ -n "$CODE" ] || { echo "no code given"; exit 1; }
[ -f run/auth.json ] || { echo "missing run/auth.json"; exit 1; }

extract() {  # $1 = raw capture, $2 = destination json
  python3 "$ROOT/bin/svjson.py" "$1" "$2"
}

step() {  # $1 = label, $2 = request json (relative), $3 = output basename
  echo
  echo "=== $1 ==="
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
    if k in d:
        print('  %-14s %r' % (k, d[k]))
open(sys.argv[1] + '.code', 'w').write(str(d.get('err_code')))
PY
}

echo "submitting 2FA code ..."
python3 bin/svmk.py otp "$CODE" run/auth.json > run/otp.json || exit 1
chmod 600 run/otp.json
step "chk_sms flag=otp (2FA)" run/otp.json otp

rc="$(cat run/otp.json.code 2>/dev/null)"
if [ "$rc" != "0" ]; then
  echo
  echo "2FA rejected (err_code=$rc)."
  echo "If that reads like a code mismatch, the code simply expired - wait for the"
  echo "next one and re-run:  ~/topsap/bin/twofa.sh"
  exit 1
fi

python3 bin/svmk.py raw '{"method":"get_config_info"}' > run/cfg.json
step "get_config_info" run/cfg.json cfg

python3 bin/svmk.py query_status > run/qs.json
step "query_status" run/qs.json qs

echo
echo "=== tunnel state (tstate_id 6 = established) ==="
python3 - <<'PY'
import json
try:
    d = json.load(open('run/qs.json'))
except Exception:
    raise SystemExit
print('  state_id=%s  tstate_id=%s  vip=%s  mask=%s'
      % (d.get('state_id'), d.get('tstate_id'), d.get('vip'), d.get('vip_mask')))
PY

if [ -n "${TOPSAP_TEST_HOST:-}" ]; then
  echo
  echo "=== reachability test, run inside the sandbox ==="
  bin/topsap run "timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no '$TOPSAP_TEST_HOST' true && echo SSH_OK || echo SSH_FAIL" | tail -3
fi
