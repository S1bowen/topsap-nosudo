#!/bin/bash
# setup.sh -- assemble a runnable topsap tree from this repository.
#
#   ./setup.sh /path/to/TopSAP-<version>-x86_64.deb
#   TOPSAP_ROOT=~/opt/topsap ./setup.sh        # if ~/topsap already has engine/
#
# It installs nothing system-wide, needs no root, and never touches anything
# outside $TOPSAP_ROOT (default ~/topsap).  Existing credentials there
# (.pwd, keys/) and live state (run/) are left alone.
#
# What it does:
#   1. copies the scripts into $TOPSAP_ROOT
#   2. extracts the vendor engine from the .deb into $TOPSAP_ROOT/engine
#   3. compiles bin/svctl (src/svctl.c) and bin/svdbg (dev/svdbg.c)
#   4. finds or links slirp4netns, and copies the libraries it needs
#   5. checks the runtime dependencies, including unprivileged userns
#   6. creates topsap.env from the example, if there is none
set -eu

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=${TOPSAP_ROOT:-$HOME/topsap}
DEB=${1:-}

say(){ printf '%s\n' "$*"; }
warn(){ printf 'setup: %s\n' "$*" >&2; }
die(){ warn "$*"; exit 1; }

[ -d "$SRC/bin" ] || die "$SRC does not look like the topsap repository"
if [ -z "$DEB" ] && [ ! -f "$ROOT/engine/sv_websrv" ]; then
  die "usage: $0 /path/to/TopSAP-<version>-x86_64.deb"
fi
[ -z "$DEB" ] || [ -f "$DEB" ] || die "no such file: $DEB"

say "installing into $ROOT"
mkdir -p "$ROOT"/{bin,engine,lib,state/ssh}

# ---------------------------------------------------------------- 1. scripts
cp -f "$SRC"/bin/*    "$ROOT/bin/"
cp -f "$SRC"/state/pxcheck.sh "$ROOT/state/pxcheck.sh"
cp -f "$SRC"/state/ssh/config.example "$ROOT/state/ssh/config.example"
cp -f "$SRC"/README.md "$SRC"/topsap.env.example "$ROOT/" 2>/dev/null || true
chmod 700 "$ROOT/bin/topsap" "$ROOT/bin"/*.sh "$ROOT/bin/svq" \
          "$ROOT/bin/sudo" "$ROOT/bin/svjson.py" "$ROOT/bin/svmk.py" 2>/dev/null || true
say "  scripts copied"

# ----------------------------------------------------------------- 2. engine
if [ -n "$DEB" ]; then
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/topsap-setup.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  say "  extracting $DEB"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$DEB" "$TMP"
  else
    # Works without dpkg (any distribution with binutils + tar).
    member=$(ar t "$DEB" 2>/dev/null | grep '^data\.tar' | head -1)
    [ -n "$member" ] || die "not a .deb: $DEB"
    case $member in
      *.xz)  flag=-J ;;
      *.gz)  flag=-z ;;
      *.bz2) flag=-j ;;
      *.zst) flag=--zstd ;;
      *)     flag= ;;
    esac
    ( cd "$TMP" && ar p "$DEB" "$member" | tar $flag -x ) \
      || die "could not extract $DEB (install dpkg or binutils)"
  fi
  V=$TMP/opt/TopSAP
  [ -f "$V/sv_websrv" ] || die "unexpected .deb layout: $V/sv_websrv not found"
  for f in sv_websrv TopVPNhelper libtopsec_vpn.so libgm3000.1.0.so \
           libes_3000gm.so.1.0.0 version sv_install.sh sv_sever.sh sv_uninstall.sh; do
    [ -f "$V/$f" ] && cp -f "$V/$f" "$ROOT/engine/$f"
  done
  chmod 700 "$ROOT/engine" "$ROOT/engine/sv_websrv" "$ROOT/engine/TopVPNhelper" 2>/dev/null || true
  say "  engine $(cat "$ROOT/engine/version" 2>/dev/null || echo '?') installed"
else
  say "  engine already present ($(cat "$ROOT/engine/version" 2>/dev/null || echo '?'))"
fi

# ------------------------------------------------------------------ 3. build
[ -f "$SRC/src/svctl.c" ] || die "src/svctl.c is missing"
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  die "no C compiler (cc/gcc) -- needed to build bin/svctl"
fi
CC=$(command -v cc || command -v gcc)
"$CC" -O2 -Wall -o "$ROOT/bin/svctl" "$SRC/src/svctl.c" || die "svctl build failed"
chmod 700 "$ROOT/bin/svctl"
say "  built bin/svctl"
if [ -f "$SRC/dev/svdbg.c" ]; then
  "$CC" -O2 -Wall -o "$ROOT/bin/svdbg" "$SRC/dev/svdbg.c" && chmod 700 "$ROOT/bin/svdbg" \
    && say "  built bin/svdbg"
fi

# --------------------------------------------------------------- 4. slirp4netns
if [ ! -x "$ROOT/bin/slirp4netns" ]; then
  if command -v slirp4netns >/dev/null 2>&1; then
    ln -sf "$(command -v slirp4netns)" "$ROOT/bin/slirp4netns"
    say "  slirp4netns -> $(command -v slirp4netns)"
  else
    warn "slirp4netns not found: install it (apt install slirp4netns, pacman -S slirp4netns)"
    warn "or drop a static build at $ROOT/bin/slirp4netns.  'topsap up' will fail without it."
  fi
fi

# The driver puts $ROOT/lib first on LD_LIBRARY_PATH, so a bundled library wins
# over the system one.  Copy only what is missing there.
if command -v ldconfig >/dev/null 2>&1; then
  for name in libslirp.so.0 libseccomp.so.2; do
    [ -e "$ROOT/lib/$name" ] && continue
    path=$(ldconfig -p 2>/dev/null | awk -v n="$name" '$1==n {print $NF; exit}')
    if [ -n "${path:-}" ] && [ -f "$path" ]; then
      cp -Lf "$path" "$ROOT/lib/$name" && say "  bundled $name"
    else
      warn "could not find $name; if 'topsap up' complains, install libslirp/libseccomp"
    fi
  done
fi

# -------------------------------------------------------------------- 5. env
if [ ! -f "$ROOT/topsap.env" ] && [ -f "$SRC/topsap.env.example" ]; then
  cp -f "$SRC/topsap.env.example" "$ROOT/topsap.env"
  chmod 600 "$ROOT/topsap.env"
  say "  wrote $ROOT/topsap.env -- edit TOPSAP_HOST / TOPSAP_USER before the first login"
fi

# ------------------------------------------------------------------ 6. checks
say ""
say "=== checks ==="
for c in unshare socat tmux python3 ip ssh; do
  if command -v "$c" >/dev/null 2>&1; then say "  ok      $c"; else warn "  MISSING $c"; fi
done
if unshare -Ur true 2>/dev/null; then
  say "  ok      unprivileged user namespaces"
else
  warn "  MISSING unprivileged user namespaces (kernel.unprivileged_userns_clone=0?)"
fi
if [ -x "$ROOT/bin/slirp4netns" ]; then
  if LD_LIBRARY_PATH="$ROOT/lib" "$ROOT/bin/slirp4netns" --version >/dev/null 2>&1; then
    say "  ok      slirp4netns ($(LD_LIBRARY_PATH="$ROOT/lib" "$ROOT/bin/slirp4netns" --version 2>&1 | head -1))"
  else
    warn "  slirp4netns does not run: it needs libslirp.so.0 in $ROOT/lib or the system"
  fi
fi

say ""
say "next:"
say "  1. edit $ROOT/topsap.env                       (gateway, account)"
say "  2. put your ssh config in ~/.ssh/config         (see $ROOT/state/ssh/config.example)"
say "  3. $ROOT/bin/vpnup.sh                           (password + TOTP)"
say "  4. $ROOT/bin/topsap ssh <alias>                 (inside the tunnel)"
