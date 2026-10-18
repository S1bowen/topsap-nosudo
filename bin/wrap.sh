#!/bin/bash
R=${TOPSAP_ROOT:-$HOME/topsap}
if [ -z "$TOPSAP_STRACE" ]; then exec ./sv_websrv; fi
strace -f -tt -s 300 -o "$R/run/engine.strace" -e trace=network,openat,execve,clone ./sv_websrv
rc=$?; echo "sv_websrv exit rc=$rc" >> "$R/run/engine.log"; exit $rc
