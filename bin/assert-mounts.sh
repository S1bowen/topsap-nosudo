#!/bin/bash
# assert-mounts.sh -- keep the sandbox's /etc/passwd mapping in place.
#
# sandbox.sh binds a generated /etc/passwd whose uid-0 home is the real home,
# because OpenSSH resolves ~/.ssh/config through getpwuid(0) rather than $HOME.
# That bind has been seen to disappear from a live mount namespace (leaving the
# generated copy on disk intact), after which ssh silently stops reading the
# config and treats host aliases as DNS names.  Re-assert it here so every
# entry point into the sandbox repairs itself instead of failing later.
#
# Runs as uid 0 inside the sandbox; a no-op everywhere else.
set -u

ROOT=${TOPSAP_ROOT:-$HOME/topsap}
SRC=$ROOT/run/etc/passwd

[ "$(id -u)" = 0 ] || exit 0
[ -r "$SRC" ] || exit 0

root_home(){ awk -F: '$1=="root" && $3==0 {print $6; exit}' "$1" 2>/dev/null; }

want=$(root_home "$SRC")
[ -n "$want" ] || exit 0
[ "$(root_home /etc/passwd)" = "$want" ] && exit 0

if mount --bind "$SRC" /etc/passwd 2>/dev/null && [ "$(root_home /etc/passwd)" = "$want" ]; then
  echo "assert-mounts: restored /etc/passwd (uid 0 home -> $want)" >&2
  exit 0
fi
echo "assert-mounts: could not restore /etc/passwd from $SRC" >&2
exit 1
