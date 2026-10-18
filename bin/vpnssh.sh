#!/bin/bash
# vpnssh.sh -- ssh to a host that is only reachable through the TopSAP tunnel.
#
#   ~/topsap/bin/vpnssh.sh vpn-login              # interactive shell
#   ~/topsap/bin/vpnssh.sh vpn-login hostname      # run one command
#   ~/topsap/bin/vpnssh.sh -v -p 22 vpn-login      # ssh options pass through
#
# tun0 exists only inside the sandbox network namespace, so ssh has to run in
# there.  sandbox.sh binds a private /etc/passwd whose uid-0 home is the real
# home, so ~/.ssh/config (your tunnel-side hosts) and ~/.ssh/id_* resolve
# normally even though we are uid 0 inside the namespaces.
#
# Normally you do not call this directly -- use:
#   ~/topsap/bin/topsap ssh vpn-login
set -u

ROOT=${TOPSAP_ROOT:-$HOME/topsap}
H=${TOPSAP_HOME:-$HOME}
SSH_OPTS=(
  -o IdentityAgent=none                 # no 1Password agent on this machine
  -o StrictHostKeyChecking=accept-new   # tunnel hosts are not in known_hosts yet
  -o ServerAliveInterval=60
  # Bound the wait.  Unbounded, an unreachable host leaves ssh sitting on the
  # kernel's TCP handshake for ~130 s before it says anything at all.
  -o ConnectTimeout="${TOPSAP_CONNECT_TIMEOUT:-30}"
)

if [ "${TOPSAP_IN_SANDBOX:-0}" = 1 ]; then
  # Already inside the namespaces: this is the real call.
  #
  # Preflight.  The sandbox can be perfectly healthy while the route into the
  # cluster is not -- the gateway dropped the session, or the tunnel never came
  # up.  Saying so here takes a second and names the fix; without it the only
  # symptom is a long silence followed by whatever the window does next.
  g=$(ssh -G "$@" 2>/dev/null)
  h=$(printf '%s\n' "$g" | awk '$1=="hostname"{print $2; exit}')
  p=$(printf '%s\n' "$g" | awk '$1=="port"{print $2; exit}')
  if [ -n "$h" ] && [ -n "$p" ] && ! timeout 8 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
    {
      echo "vpnssh: cannot reach $h:$p from inside the tunnel."
      echo "        The sandbox is up, so either this address is not routed through"
      echo "        the VPN or the tunnel has gone away (it needs a live login)."
      echo "        check :  ~/topsap/bin/topsap vpn          # tunnel state"
      echo "                 ~/topsap/bin/topsap run 'ip route' # vpn subnet via tun0?"
      echo "        fix   :  ~/topsap/bin/vpnup.sh             # log in again"
    } >&2
    # Whoever put us here holds the window open so this stays readable; when we
    # were reached non-interactively, exiting is the whole answer.
    exit 255
  fi
  if [ -n "${TOPSAP_SSH_LOG:-}" ]; then
    exec ssh "${SSH_OPTS[@]}" -E "$TOPSAP_SSH_LOG" "$@"
  fi
  exec ssh "${SSH_OPTS[@]}" "$@"
fi

[ -x "$ROOT/bin/topsap" ] || { echo "vpnssh: no $ROOT/bin/topsap" >&2; exit 1; }
[ -S "$ROOT/run/ctl.sock" ] || {
  echo "vpnssh: the sandbox is not running -- start it first:" >&2
  echo "          rm -f $ROOT/.pwd && $ROOT/bin/vpnup.sh" >&2
  exit 1
}

# Interactive ssh needs a real pty, which the socat control channel cannot give
# it; hand that case to 'topsap ssh', which uses a tmux window instead.
if [ $# -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
  exec "$ROOT/bin/topsap" ssh "$1"
fi

q=$(printf '%q ' "$@")
exec "$ROOT/bin/topsap" run "TOPSAP_IN_SANDBOX=1 HOME='$H' $ROOT/bin/vpnssh.sh $q"
