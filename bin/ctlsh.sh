#!/bin/bash
cd "${HOME:-/}" 2>/dev/null || cd /tmp
IFS= read -r line || exit 0
[ -z "$line" ] && exit 0
# ssh inside here needs the sandbox's private /etc/passwd; it has been observed
# to go missing from a live namespace, so repair it on every entry.
command -v assert-mounts.sh >/dev/null 2>&1 && assert-mounts.sh
bash -c "$line"
printf '\n@@rc=%d\n' "$?"
