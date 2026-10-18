#!/bin/bash
# Runs ON the far side, fed to `bash -s` through the tunnel by
#   ~/topsap/bin/topsap pxcheck
# It only reads: it prints what this host sees for the reverse proxy that
# `topsap proxy up` published here.  The port arrives as PXPORT.
PORT=${PXPORT:-18438}
PX=127.0.0.1:$PORT
# /proc/net/tcp prints the port in hex; derive it rather than hardcoding.
HEX=$(printf '%04X' "$PORT" 2>/dev/null)

echo "host      : $(hostname)"
echo "user      : $(id -un)"
echo "port      : $PORT"

# Believe a direct connect over any socket-count guess: 'ss' may be absent, and
# 'grep -c' prints 0 rather than nothing when it finds nothing.
if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  echo "listening : yes (127.0.0.1:$PORT accepts connections)"
else
  echo "listening : NO  -- nothing on 127.0.0.1:$PORT"
fi
echo "sockets   : ss=$(ss -ltn 2>/dev/null | grep -c ":$PORT") proc=$(awk '{print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c ":$HEX\$")"

if command -v curl >/dev/null 2>&1; then
  echo "http  via : $(curl -s -x "http://$PX" -o /dev/null -w '%{http_code}' --max-time 15 http://example.com 2>/dev/null || echo FAIL)"
  echo "https via : $(curl -s -x "http://$PX" -o /dev/null -w '%{http_code}' --max-time 15 https://example.com 2>/dev/null || echo FAIL)"
  echo "egress ip : $(curl -s -x "http://$PX" --max-time 15 https://api.ipify.org 2>/dev/null || echo FAIL)"
else
  echo "curl      : not installed on the far side (checks skipped)"
fi

echo
echo "use it there with:  export http_proxy=http://$PX https_proxy=http://$PX"
