#!/bin/bash
# pack.sh [SRC] [OUT] -- build the portable, secret-free tarball.
#
#   ~/topsap/bin/pack.sh                     # ~/topsap  ->  ~/topsap-<ver>-portable.tar.gz
#
# The tarball unpacks to a single top-level `topsap/` directory, so
#   tar xzf topsap-<ver>-portable.tar.gz -C ~
# is the whole install.
#
# Deliberately excluded: the VPN password (.pwd), the ssh keys (keys/), the live
# control files (run/), and the development-only probes.  Credentials travel
# separately -- see the "Install" section of README.md.
set -eu

SRC=${1:-$HOME/topsap}
VER=$(cat "$SRC/engine/version" 2>/dev/null || echo unknown)
VER=${VER//[!0-9A-Za-z._-]/}
OUT=${2:-$HOME/topsap-$VER-portable.tar.gz}

[ -d "$SRC/engine" ] || { echo "pack: $SRC does not look like a topsap tree" >&2; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/topsap-pack.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

EXCL=(
  --exclude=./run
  --exclude=./req
  --exclude=./keys
  --exclude=./.pwd
  --exclude=./bin/fake443_test.sh
  --exclude=./bin/handshake_test.sh
  --exclude=./bin/strace_authparam.sh
  --exclude='./*.strace'
  --exclude='./*.log'
  --exclude='./__pycache__'
  --exclude='./*.pyc'
)

mkdir -p "$STAGE/topsap"
tar -C "$SRC" -cf - "${EXCL[@]}" . | tar -C "$STAGE/topsap" -xf -

# Restore the modes the driver depends on: the tree must stay writable by its
# owner, but a private key or a password file must never be group-world readable.
chmod 700 "$STAGE/topsap/bin" "$STAGE/topsap/engine" 2>/dev/null || true
chmod 600 "$STAGE/topsap/.pwd" 2>/dev/null || true

# And the modes the *tarball* depends on.  tar copies file modes verbatim, so
# whatever the source tree happens to say is what the other machine gets -- and
# editors and file transfers routinely drop the execute bit (a file written
# through an editor is 0644, and `scp` between machines copies that 0644 over a
# perfectly good 0700).  A tarball built from such a tree installs cleanly and
# then fails with `Permission denied` the first time anyone runs the driver, so
# set these here instead of inheriting them.
for f in topsap sandbox.sh vpnup.sh vpnssh.sh ctlsh.sh pack.sh twofa.sh \
         wrap.sh svjson.py svmk.py svctl svq svdbg sudo slirp4netns; do
  [ -e "$STAGE/topsap/bin/$f" ] || continue
  chmod 700 "$STAGE/topsap/bin/$f"
done

( cd "$STAGE/topsap" && find . -type f ! -name MANIFEST.txt -print0 \
    | sort -z | xargs -0 sha256sum ) > "$STAGE/topsap/MANIFEST.txt"

tar -C "$STAGE" -czf "$OUT" topsap
echo "packed $OUT"
echo "  version : $VER"
echo "  size    : $(du -h "$OUT" | cut -f1)"
echo "  files   : $(find "$STAGE/topsap" -type f | wc -l)"
