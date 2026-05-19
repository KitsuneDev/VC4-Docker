#!/usr/bin/env bash
set -Eeuo pipefail

sleep 1
exec /usr/local/sbin/vc4-container-restart.sh >> /var/log/vc4-container-restart.log 2>&1
