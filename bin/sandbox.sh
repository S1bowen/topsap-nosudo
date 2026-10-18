#!/bin/bash
R=${TOPSAP_ROOT:-$HOME/topsap}
BIN=$R/bin; ENGINE=$R/engine; STATE=$R/state; RUN=$R/run
RH=${TOPSAP_HOME:-$HOME}          # the real home, as seen before the sandbox
log(){ echo "[sandbox] $*"; }
echo $$ > "$RUN/ns.pid"
while [ ! -e "$RUN/slirp.ok" ]; do sleep 0.2; done
mount --make-rprivate /
# /sys must describe THIS namespace's network interfaces.  An inherited
# host sysfs superblock makes libtopsec_vpn.so's "ls /sys/class/net/" step
# blind to the tun device it just created (tunnel setup then fails).
if mount -t sysfs sysfs /sys 2>/dev/null; then log "fresh sysfs OK"; else log "fresh sysfs FAILED"; fi
for f in hosts resolv.conf; do
  if mount --bind "$STATE/$f" "/etc/$f" 2>/dev/null; then log "bind /etc/$f OK"; else log "bind /etc/$f FAILED"; fi
done

# OpenSSH resolves ~/.ssh/config and ~/.ssh/id_* through getpwuid(getuid()),
# not through $HOME.  Inside the sandbox uid 0's passwd home is /root, which the
# host owns and this namespace cannot even traverse, so ssh would never see the
# ssh config and keys we synced.  Point uid 0 at the real home instead -- a
# private bind of a generated copy, so /etc/passwd itself is untouched.
mkdir -p "$RUN/etc"
if awk -F: -v h="$RH" 'BEGIN{OFS=":"} $1=="root" && $3==0 {$6=h} {print}' /etc/passwd > "$RUN/etc/passwd" 2>/dev/null \
   && chmod 644 "$RUN/etc/passwd" \
   && mount --bind "$RUN/etc/passwd" /etc/passwd 2>/dev/null; then
  log "passwd: uid 0 home -> $RH"
else
  log "passwd remap FAILED (ssh will not find ~/.ssh/config)"
fi

mkdir -p "$RUN/optup" "$RUN/optwork"
if mount -t overlay ovlopt -o "lowerdir=/opt,upperdir=$RUN/optup,workdir=$RUN/optwork" /opt 2>/dev/null; then
  log "overlay /opt OK"
else
  mkdir -p "$RUN/optroot"
  mount --bind "$RUN/optroot" /opt 2>/dev/null && log "bind /opt OK" || log "opt FAILED"
fi
ip link set lo up 2>/dev/null && log "lo up"
mkdir -p /tmp/TopSAP_ELE/.BUFF 2>/dev/null
mkdir -p /opt/sslvpn/config /opt/sslvpn/client_Resource /opt/TopSAP
cp -f "$ENGINE/libtopsec_vpn.so" /opt/TopSAP/libtopsec_vpn.so 2>/dev/null && log "seeded /opt/TopSAP/libtopsec_vpn.so"
export PATH="$BIN:$PATH"
export LD_LIBRARY_PATH="$ENGINE:$R/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cd "$HOME" || cd /tmp
socat UNIX-LISTEN:"$RUN/ctl.sock",fork,mode=600 EXEC:"$BIN/ctlsh.sh",stderr >/dev/null 2>&1 &
# A tmux server inherits the network namespace of whoever starts it, so this
# one must be born in here -- a server started from the host side has no tun0
# and every window in it would ssh into nothing.  (The sockets live in $RUN,
# which is a private tmpfs mount, so the host cannot reach it either.)
# The first window is a keeper that never exits: the server dies with its last
# window, and if it dies the next 'topsap ssh' would silently fall back to the
# host namespace.
tmux -S "$RUN/tmux.sock" new-session -d -s topsap -n keeper \
  'sh -c "while :; do sleep 3600; done"' 2>>"$RUN/sandbox.log"
( cd "$ENGINE" && exec "$BIN/wrap.sh" >"$RUN/engine.log" 2>&1 ) &
echo $! > "$RUN/engine.pid"
log "engine pid $(cat "$RUN/engine.pid")"
touch "$RUN/ready"
log "ready"
while :; do sleep 3600; done
