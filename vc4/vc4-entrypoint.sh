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

apache_auth_block() {
  local location="$1"
  local service="$2"
  local require_ssl="${VC4_PAM_REQUIRE_SSL:-true}"

  printf '<Location "%s">\n' "$location"
  if [[ "$require_ssl" == "true" ]]; then
    printf '  SSLRequireSSL\n'
  fi
  printf '  AuthType Basic\n'
  printf '  AuthName "PAM Authentication"\n'
  printf '  AuthBasicProvider PAM\n'
  printf '  AuthPAMService %s\n' "$service"
  printf '  Require valid-user\n'
  printf '</Location>\n'
}

write_pam_service() {
  local service="$1"
  local credentials_file="$2"
  local pam_file="/etc/pam.d/$service"

  cat > "$pam_file" <<EOF
auth required pam_exec.so expose_authtok quiet /usr/local/sbin/vc4-pam-file-auth.sh $credentials_file
account required pam_permit.so
EOF
}

write_credentials_file() {
  local path="$1"
  local username="$2"
  local password="$3"

  mkdir -p "$(dirname "$path")"
  printf '%s\t%s\n' "$username" "$password" > "$path"
  chgrp apache "$path" || true
  chmod 0640 "$path"
}

sanitize_pam_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

configure_pam_authentication() {
  local conf="/opt/crestron/virtualcontrol/conf/crestron.conf"
  local block_file="/tmp/vc4-pam-hardening.conf"
  local marker_begin="# VC4 Docker PAM hardening begin"
  local marker_end="# VC4 Docker PAM hardening end"
  local enabled=false

  if [[ ! -f "$conf" ]]; then
    log "WARNING: Apache VC4 config not found: $conf"
    return 0
  fi

  perl -0pi -e 's|\n# VC4 Docker PAM hardening begin\n.*?\n# VC4 Docker PAM hardening end\n||s' "$conf"

  : > "$block_file"
  printf '%s\n' "$marker_begin" >> "$block_file"

  if [[ "${VC4_PAM_ADMIN_ENABLED:-false}" == "true" ]]; then
    if [[ -z "${VC4_PAM_ADMIN_USERNAME:-}" || -z "${VC4_PAM_ADMIN_PASSWORD:-}" ]]; then
      log "WARNING: VC4_PAM_ADMIN_ENABLED is true but admin username/password is missing"
    else
      write_credentials_file "/etc/httpd/conf.d/vc4-pam-admin.credentials" "$VC4_PAM_ADMIN_USERNAME" "$VC4_PAM_ADMIN_PASSWORD"
      write_pam_service "vc4-admin-auth" "/etc/httpd/conf.d/vc4-pam-admin.credentials"
      apache_auth_block '${CRESTRON_VC_4_WEBROOT}/config/settings/' "vc4-admin-auth" >> "$block_file"
      enabled=true
    fi
  fi

  if [[ "${VC4_PAM_STATUS_ENABLED:-false}" == "true" ]]; then
    if [[ -z "${VC4_PAM_STATUS_USERNAME:-}" || -z "${VC4_PAM_STATUS_PASSWORD:-}" ]]; then
      log "WARNING: VC4_PAM_STATUS_ENABLED is true but status username/password is missing"
    else
      write_credentials_file "/etc/httpd/conf.d/vc4-pam-status.credentials" "$VC4_PAM_STATUS_USERNAME" "$VC4_PAM_STATUS_PASSWORD"
      write_pam_service "vc4-status-auth" "/etc/httpd/conf.d/vc4-pam-status.credentials"
      apache_auth_block '${CRESTRON_VC_4_WEBROOT}/config/status/' "vc4-status-auth" >> "$block_file"
      enabled=true
    fi
  fi

  if [[ -n "${VC4_PAM_ROOM_CREDENTIALS_FILE:-}" ]]; then
    if [[ ! -f "$VC4_PAM_ROOM_CREDENTIALS_FILE" ]]; then
      log "WARNING: VC4_PAM_ROOM_CREDENTIALS_FILE not found: $VC4_PAM_ROOM_CREDENTIALS_FILE"
    else
      while IFS=$'\t' read -r room_id username password targets _ || [[ -n "${room_id:-}" ]]; do
        [[ -z "${room_id:-}" || "${room_id:0:1}" == "#" ]] && continue
        if [[ -z "${username:-}" || -z "${password:-}" ]]; then
          log "WARNING: skipping PAM room entry with missing username/password for room: $room_id"
          continue
        fi

        local safe_room
        safe_room="$(sanitize_pam_id "$room_id")"
        local service="vc4-room-${safe_room}-auth"
        local credentials="/etc/httpd/conf.d/vc4-pam-room-${safe_room}.credentials"
        write_credentials_file "$credentials" "$username" "$password"
        write_pam_service "$service" "$credentials"

        targets="${targets:-cws,xpanel,html}"
        if [[ ",$targets," == *",cws,"* ]]; then
          apache_auth_block '${CRESTRON_VC_4_WEBROOT}/Rooms/'"$room_id"'/cws/' "$service" >> "$block_file"
        fi
        if [[ ",$targets," == *",xpanel,"* ]]; then
          apache_auth_block '${CRESTRON_VC_4_WEBROOT}/Rooms/'"$room_id"'/XPanel/Core3XPanel.html' "$service" >> "$block_file"
        fi
        if [[ ",$targets," == *",html,"* ]]; then
          apache_auth_block '${CRESTRON_VC_4_WEBROOT}/Rooms/'"$room_id"'/Html/' "$service" >> "$block_file"
        fi
        enabled=true
      done < "$VC4_PAM_ROOM_CREDENTIALS_FILE"
    fi
  fi

  if [[ "$enabled" != "true" ]]; then
    rm -f "$block_file"
    return 0
  fi

  printf '%s\n' "$marker_end" >> "$block_file"
  log "Adding Docker PAM hardening rules to Apache VC4 config"
  perl -0pi -e 's|# Settings api redirect|do { local $/; open my $fh, "<", "/tmp/vc4-pam-hardening.conf"; <$fh> } . "\n# Settings api redirect"|e' "$conf"
}

configure_tls_certificates() {
  local ssl_conf="/opt/crestron/virtualcontrol/conf/ssl.conf"

  if [[ -z "${VC4_TLS_CERT_FILE:-}" && -z "${VC4_TLS_KEY_FILE:-}" ]]; then
    return 0
  fi

  if [[ -z "${VC4_TLS_CERT_FILE:-}" || -z "${VC4_TLS_KEY_FILE:-}" ]]; then
    log "WARNING: both VC4_TLS_CERT_FILE and VC4_TLS_KEY_FILE are required to configure TLS"
    return 0
  fi

  if [[ ! -f "$VC4_TLS_CERT_FILE" || ! -f "$VC4_TLS_KEY_FILE" ]]; then
    log "WARNING: TLS cert/key file not found; cert=$VC4_TLS_CERT_FILE key=$VC4_TLS_KEY_FILE"
    return 0
  fi

  log "Configuring VC4 TLS certificate paths"
  printf 'SSLCertificateFile %s\nSSLPrivateKeyFile %s\n' "$VC4_TLS_CERT_FILE" "$VC4_TLS_KEY_FILE" > "$ssl_conf"
  chown virtualcontroluser.virtualcontroluser "$ssl_conf" || true
}

configure_flash_policy() {
  local mode="${VC4_FLASH_POLICY_MODE:-}"
  local conf="/opt/crestron/virtualcontrol/conf/FlashPolicyServer.conf"
  local secure="Off"
  local state="Enabled"
  local domain="${VC4_FLASH_POLICY_DOMAIN:-*}"
  local port="${VC4_FLASH_POLICY_PORT:-1025}"

  [[ -z "$mode" ]] && return 0

  case "$mode" in
    disabled) state="Disabled"; secure="Off" ;;
    secure) state="Enabled"; secure="On" ;;
    unsecure|unsecured) state="Enabled"; secure="Off" ;;
    *)
      log "WARNING: unsupported VC4_FLASH_POLICY_MODE '$mode' (expected disabled, secure, or unsecure)"
      return 0
      ;;
  esac

  log "Configuring VC4 Flash policy server: mode=$mode domain=$domain port=$port"
  cat > "$conf" <<EOF
FlashPolicyServer = $state
Secure = $secure
Domain = $domain
Port = $port
EOF
  chown virtualcontroluser.virtualcontroluser "$conf" || true
}

configure_cgroup_settings() {
  local target="/opt/crestron/virtualcontrol/conf/vc4cgconfig.conf"

  if [[ -z "${VC4_CGROUP_CONFIG_FILE:-}" ]]; then
    return 0
  fi

  if [[ ! -f "$VC4_CGROUP_CONFIG_FILE" ]]; then
    log "WARNING: VC4_CGROUP_CONFIG_FILE not found: $VC4_CGROUP_CONFIG_FILE"
    return 0
  fi

  log "Installing VC4 cgroup config from $VC4_CGROUP_CONFIG_FILE"
  cp "$VC4_CGROUP_CONFIG_FILE" "$target"
  chown virtualcontroluser.virtualcontroluser "$target" || true
  cgconfigparser --load="$target" || true
}

apply_system_table_hardening() {
  local payload=""
  local api="http://127.0.0.1/VirtualControl/config/settings/WebApi/SystemTable"

  if [[ -n "${VC4_SECURE_GATEWAY_MODE:-}" ]]; then
    payload="\"SecureGatewayMode\":$VC4_SECURE_GATEWAY_MODE"
  fi
  if [[ -n "${VC4_OCSP_STATE:-}" ]]; then
    [[ -n "$payload" ]] && payload="$payload,"
    payload="${payload}\"OCSPState\":$VC4_OCSP_STATE"
  fi

  [[ -z "$payload" ]] && return 0

  log "Applying VC4 SystemTable hardening settings"
  curl -fsS -m 10 -X PUT -H 'Content-Type: application/json' -d "{$payload}" "$api" || \
    log "WARNING: failed to apply VC4 SystemTable hardening settings"
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
configure_tls_certificates
configure_flash_policy
configure_cgroup_settings
configure_pam_authentication
patch_restart_service_endpoint
patch_frontend_localhost_mocks
start_first_available "Apache/HTTPD" httpd.service apache2.service
start_virtualcontrol_direct
apply_system_table_hardening

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
