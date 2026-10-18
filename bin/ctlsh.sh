#!/bin/bash
cd "${HOME:-/}" 2>/dev/null || cd /tmp
IFS= read -r line || exit 0
[ -z "$line" ] && exit 0
bash -c "$line"
printf '\n@@rc=%d\n' "$?"
