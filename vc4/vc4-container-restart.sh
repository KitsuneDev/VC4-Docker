#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[$(date --iso-8601=seconds)] $*"
}

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

source_vc4_environment() {
  local env_file="/opt/crestron/virtualcontrol/conf/env_variables.cfg"

  if [[ -f "$env_file" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$env_file"
    set -u
  fi
}

run_vendor_script() {
  local script="$1"
  shift

  if [[ ! -x "$script" ]]; then
    log "WARNING: vendor script not found or not executable: $script"
    return 1
  fi

  set +u
  "$script" "$@"
  local rc=$?
  set -u
  return "$rc"
}

port_5000_listening() {
  command -v ss >/dev/null 2>&1 && ss -ltn | grep -qE '127\.0\.0\.1:5000\b'
}

stop_vc4_processes() {
  local vc4_bin="/opt/crestron/virtualcontrol/CrestronApps/bin"
  local pattern='AppWatchdog|WebApp|DBApp|LicenseSvc|jwtprocessor|CIPCmdProcessor|DebuggingRouter|FPServer|LogicEngine|AuditLogService|XioCloudRoomApp|SNMPCommandProcessor|BACnet|TLDM|HydrogenManager|CrestronTimerEventEngine|monitorcertificates|AuthIntf'

  log "Stopping VC4 application processes"
  run_vendor_script "$vc4_bin/startVC4.sh" stop || true
  run_vendor_script "$vc4_bin/startVC4Root.sh" stop || true

  pkill -TERM -f "$pattern" || true
  sleep 3
  pkill -KILL -f "$pattern" || true
}

start_vc4_processes() {
  local vc4_bin="/opt/crestron/virtualcontrol/CrestronApps/bin"

  log "Starting VC4 application processes"
  run_vendor_script "$vc4_bin/cleanupVC4.sh" start || true
  run_vendor_script "$vc4_bin/startRedis.sh" start || true
  run_vendor_script "$vc4_bin/startVC4Root.sh" start || true
  run_vendor_script "$vc4_bin/startVC4.sh" start || true

  sleep 10
  if ! port_5000_listening; then
    log "WebApp is not listening on 127.0.0.1:5000; starting it directly"
    run_vendor_script "$vc4_bin/startNative.sh" WebApp webapp 0 NOPARAM "${TZ:-America/New_York}" || true
    sleep 5
  fi

  pgrep -af 'AppWatchdog|AuthIntf|AuditLogService|DBApp|LogicEngine|WebApp|redis-server' || true
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp || true
  fi
}

main() {
  source_vc4_environment
  log "Container VC4 restart requested"
  stop_vc4_processes
  start_vc4_processes
  log "Container VC4 restart complete"
}

main "$@"
