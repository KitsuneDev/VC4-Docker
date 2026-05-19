#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[$(date --iso-8601=seconds)] $*"
}

# The VC4 vendor scripts source env_variables.cfg, which references
# LD_LIBRARY_PATH directly. Keep nounset for our code, but give those scripts
# the traditional shell environment they expect.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

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

patch_frontend_localhost_mocks() {
  local main_js="/opt/crestron/virtualcontrol/webui/main.js"

  if [[ "${VC4_DISABLE_FRONTEND_LOCALHOST_MOCKS:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -f "$main_js" ]] && grep -q '"localhost"' "$main_js"; then
    log "Disabling frontend localhost mock-data branches in main.js"
    perl -0pi -e 's/"localhost"/"__vc4_localhost_mock_disabled__"/g' "$main_js"
  fi
}

patch_restart_service_endpoint() {
  local conf="/opt/crestron/virtualcontrol/conf/crestron.conf"

  if [[ ! -f "$conf" ]]; then
    log "WARNING: Apache VC4 config not found: $conf"
    return 0
  fi

  perl -0pi -e 's|\n# VC4 Docker RestartService override\nProxyPass "/VirtualControl/config/settings/WebApi/RestartService" "!"\nScriptAlias "/VirtualControl/config/settings/WebApi/RestartService" "/usr/local/libexec/vc4-restart-service.cgi"\n<Directory "/usr/local/libexec">\n  Options \+ExecCGI\n  Require all granted\n</Directory>\n\n|\n|g' "$conf"
  perl -0pi -e 's|<LocationMatch "\^\$\{CRESTRON_VC_4_WEBROOT\}/config/settings/WebApi/\(\?!RestartService\\\$\)">(\n\s+ProxyPass "http://127\.0\.0\.1:\$\{CRESTRON_WEBAPI_CGI_PORT\}/"\n\s+ProxyPassReverse "http://127\.0\.0\.1:\$\{CRESTRON_WEBAPI_CGI_PORT\}/"\n\s+Header set Cache-Control "max-age=0, no-cache, no-store, must-revalidate, private"\n\s+Header set Pragma "no-cache"\n)</LocationMatch>|<Location "\${CRESTRON_VC_4_WEBROOT}/config/settings/WebApi/">$1</Location>|g' "$conf"

  if [[ "${VC4_ENABLE_RESTART_SERVICE_SHIM:-false}" != "true" ]]; then
    return 0
  fi

  perl -0pi -e 's|AliasMatch "\(\?i\)\^\$\{CRESTRON_VC_4_WEBROOT\}/config/status\(.\*\)"|# VC4 Docker RestartService override\nProxyPass "/VirtualControl/config/settings/WebApi/RestartService" "!"\nScriptAlias "/VirtualControl/config/settings/WebApi/RestartService" "/usr/local/libexec/vc4-restart-service.cgi"\n<Directory "/usr/local/libexec">\n  Options +ExecCGI\n  Require all granted\n</Directory>\n\nAliasMatch "(?i)^\${CRESTRON_VC_4_WEBROOT}/config/status(.*)"|' "$conf"

  # Keep every settings WebApi route on the vendor backend except the service
  # restart URL. The original broad Location proxy wins over ScriptAlias, so
  # narrow it with a negative match instead of relying on Location precedence.
  perl -0pi -e 's|<Location(?:Match)? "\^?\$?\{?CRESTRON_VC_4_WEBROOT\}?/config/settings/WebApi/[^"]*">(\n\s+ProxyPass "http://127\.0\.0\.1:\$\{CRESTRON_WEBAPI_CGI_PORT\}/"\n\s+ProxyPassReverse "http://127\.0\.0\.1:\$\{CRESTRON_WEBAPI_CGI_PORT\}/"\n\s+Header set Cache-Control "max-age=0, no-cache, no-store, must-revalidate, private"\n\s+Header set Pragma "no-cache"\n)</Location(?:Match)?>|<LocationMatch "^\${CRESTRON_VC_4_WEBROOT}/config/settings/WebApi/(?!RestartService\$)">$1</LocationMatch>|' "$conf"
}

unit_exists() {
  local unit="$1"
  [[ -f "/etc/systemd/system/$unit" || -f "/usr/lib/systemd/system/$unit" || -f "/lib/systemd/system/$unit" ]]
}

start_first_available() {
  local label="$1"
  shift

  for unit in "$@"; do
    if unit_exists "$unit"; then
      log "Starting $label via $unit"
      systemctl start "$unit"
      systemctl status "$unit" || true
      return 0
    fi
  done

  log "WARNING: no unit found for $label: $*"
  return 1
}

stop_first_available() {
  local label="$1"
  shift

  for unit in "$@"; do
    if unit_exists "$unit"; then
      log "Stopping $label via $unit"
      systemctl stop "$unit" || true
      return 0
    fi
  done

  return 0
}

# VC4 Code
start_virtualcontrol_direct() {
  local vc4_bin="/opt/crestron/virtualcontrol/CrestronApps/bin"

  log "Starting VirtualControl directly"

  run_vendor_script "$vc4_bin/cleanupVC4.sh" start || true

  # docker-systemctl cannot keep virtualcontrol.service active because the
  # packaged startVC4.sh backgrounds AppWatchdog and exits. Reproduce the
  # service hooks explicitly instead.
  run_vendor_script "$vc4_bin/startRedis.sh" start || true
  run_vendor_script "$vc4_bin/startVC4Root.sh" start || true

  # The installer runs this AppWatchdog mode once to populate the Crestron
  # registry. Named Docker volumes can preserve an incomplete registry from an
  # earlier failed boot, so keep this idempotent initializer in the runtime path.
  run_vendor_script "$vc4_bin/AppWatchdog" hsaHerotSdnAetaluclaC || true

  if [[ -x "$vc4_bin/startVC4.sh" ]]; then
    run_vendor_script "$vc4_bin/startVC4.sh" start
  else
    log "ERROR: startVC4.sh not found"
    return 1
  fi

  sleep 10
  if command -v ss >/dev/null 2>&1 && ! ss -ltn | grep -qE '127\.0\.0\.1:5000\b'; then
    log "WebApp is not listening on 127.0.0.1:5000; starting it directly"
    run_vendor_script "$vc4_bin/startNative.sh" WebApp webapp 0 NOPARAM "${TZ:-America/New_York}" || true
    sleep 5
  fi

  pgrep -af 'AppWatchdog|AuthIntf|AuditLogService|DBApp|LogicEngine|WebApp|Crestron|virtualcontrol|redis-server' || true
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp || true
  fi
}

stop_virtualcontrol_direct() {
  local vc4_bin="/opt/crestron/virtualcontrol/CrestronApps/bin"

  log "Stopping VirtualControl directly"

  run_vendor_script "$vc4_bin/startVC4.sh" stop || true
  run_vendor_script "$vc4_bin/startVC4Root.sh" stop || true
  run_vendor_script "$vc4_bin/startRedis.sh" stop || true
}

shutdown() {
  log "Stopping VC4 container services..."
  stop_virtualcontrol_direct
  stop_first_available "Apache/HTTPD" httpd.service apache2.service
  stop_first_available "Redis" redis.service redis-server.service
  stop_first_available "MariaDB/MySQL" mariadb.service mysql.service
  exit 0
}



trap shutdown SIGTERM SIGINT

touch \
  /var/log/systemctl.log \
  /tmp/.vc4InstallationLog.txt \
  /var/log/httpd/access_log \
  /var/log/httpd/error_log

# Rocky/RHEL names are usually mariadb, redis, and httpd.
# Your original runtime script used Debian-ish names like apache2 and redis-server.
start_first_available "MariaDB/MySQL" mariadb.service mysql.service
#start_first_available "Redis" redis.service redis-server.service
patch_restart_service_endpoint
patch_frontend_localhost_mocks
start_first_available "Apache/HTTPD" httpd.service apache2.service
start_virtualcontrol_direct

log "VC4 services started. Streaming logs..."

find /opt/crestron/virtualcontrol -maxdepth 5 -type f \
  \( -iname '*.log' -o -iname '*log*' \) \
  2>/dev/null | sort | head -n 20 || true

VC4_LOGS="$(find /opt/crestron/virtualcontrol -type f \
  \( -iname '*.log' -o -path '*/logs/*' -o -path '*/log/*' -o -name 'vc4InstallationLog.txt' \) \
  ! -path '*/lib/*' \
  ! -path '*/mono/*' \
  ! -path '*/webui/*' \
  ! -path '*/virtualcontrolenv/*' \
  2>/dev/null | sort | head -n 30)"

tail -n +1 -F \
  /var/log/httpd/access_log \
  /var/log/httpd/error_log \
  $VC4_LOGS

wait $!
