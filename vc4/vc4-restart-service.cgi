#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${REQUEST_METHOD:-GET}" != "POST" ]]; then
  printf 'Status: 405 Method Not Allowed\r\n'
  printf 'Allow: POST, OPTIONS\r\n'
  printf 'Content-Type: application/json\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf '\r\n'
  printf '{"status":"error","message":"RestartService accepts POST only"}\n'
  exit 0
fi

nohup /usr/bin/sudo -n /usr/local/sbin/vc4-container-restart-launch.sh \
  >/dev/null 2>&1 < /dev/null &

printf 'Status: 202 Accepted\r\n'
printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
printf '{"status":"accepted","message":"VC4 restart scheduled"}\n'
