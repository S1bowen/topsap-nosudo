#!/bin/bash
# genreq.sh HOST PORT USER   --  rebuild the request fixtures used by the
# probes in this directory.  The password is read from stdin (once) and is
# never written anywhere: the files contain only the vendor's RSA-encrypted
# blob, and live under ~/topsap/req (gitignored, mode 600).
set -e

ROOT=${TOPSAP_ROOT:-$HOME/topsap}
B=$ROOT/bin
REQ=$ROOT/req

if [ $# -ne 3 ]; then
    echo "usage: $0 HOST PORT USER   (password on stdin)" >&2
    exit 2
fi
H=$1; P=$2; U=$3

[ -x "$B/svctl" ] || { echo "$B/svctl missing -- run setup.sh first" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

printf 'VPN password: ' >&2
IFS= read -rs PW || true
echo >&2
[ -n "$PW" ] || { echo "empty password" >&2; exit 2; }

mkdir -p "$REQ"
chmod 700 "$REQ"
umask 077

python3 -I "$B/svmk.py" query_status > "$REQ/q.json"

python3 -I "$B/svmk.py" raw \
    "{\"method\": \"check_line\", \"connection\": \"$H:$P\", \"addr\": \"$H\", \"port\": \"$P\"}" \
    > "$REQ/cl.json"

printf '%s' "$PW" | python3 -I "$B/svmk.py" authparam "$H" "$P" "$U" > "$REQ/ap.json"
printf '%s' "$PW" | python3 -I "$B/svmk.py" login "$H" "$P" "$U" "$REQ/ap.json" > "$REQ/lg.json"
unset PW

chmod 600 "$REQ"/*.json
echo "wrote $REQ/{q,cl,ap,lg}.json" >&2
