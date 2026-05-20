# VC4 Docker

Docker packaging for Crestron Virtual Control (VC-4) on Rocky Linux 9.

This image runs the vendor VC-4 services directly inside the container (sadly necessary) and includes Docker-specific shims and packages to provide full VC4 functionality.

## Prerequisites

- Docker Compose
- The VC-4 installer zip at `vc4/installer/vc4.zip`
- Enough memory and CPU for the VC-4 workload you plan to run



## Quick Start

# Building

**Supply your own installer!** Download Crestron VC4 installer [from their official webpage]() and place it as `vc4/installer/vc4.zip`.
* Do not share the ZIP file. Crestron restricts it to authorized users only.
* Make sure the installer targets RHEL/Rocky 9. (There should be a folder inside it called `el9`)
* Distributing a built image would probably go against Crestron's TOS. Build it locally, or use a private registry.

# Running

```powershell
Copy-Item .env.example .env
docker compose build vc4
docker compose up -d vc4
```

Open:

- Admin UI: `http://localhost:8847/VirtualControl/config/settings/`
- Status UI: `http://localhost:8847/VirtualControl/config/status/`
- HTTPS: `https://localhost:8848/...`

Persistent data is stored in named volumes:

- `vc4_mysql`
- `vc4_crestron`
- `vc4_redis`

## Patches

These are enabled in `docker-compose.yml`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VC4_DISABLE_FRONTEND_LOCALHOST_MOCKS` | `true` | Normally, accessing VC4 through `localhost` doesn't actually connect to the backend, and just loads Mock data. This fixes it. |
| `VC4_ENABLE_RESTART_SERVICE_SHIM` | `true` | Allows VC-4 service restarts to work inside Docker, including the Restart button and backend calls to `systemctl restart virtualcontrol.service`. |
| [TLS Certificates](#tls-certificates) | `Off` | Handles building the TLS Config. |
| [Flash Policy Server](#flash-policy-server) | `Off` | Configures the VC-4 Flash policy server. |
| [PAM Authentication](#pam-authentication) | `Off` | Allows you to set username/password combinations for Admin and individual rooms. |

## Hardening Options

The hardening options are based on Crestron's "Harden the Crestron Virtual Control Software" guidance:

<https://docs.crestron.com/en-us/8912/Content/Topics/Secure-Deployment/Harden-VC-4.htm>

Files referenced below should be mounted under `/run/vc4-hardening`. The default compose file already mounts `./data/hardening:/run/vc4-hardening:ro`.

### TLS Certificates

VC-4 reads TLS paths from `/opt/crestron/virtualcontrol/conf/ssl.conf`. Set both variables:

```env
VC4_TLS_CERT_FILE=/run/vc4-hardening/server.crt
VC4_TLS_KEY_FILE=/run/vc4-hardening/server.key
```

The certificate and key must be PEM, unencrypted, and a matching RSA pair. If no cert is supplied, the image creates a fallback self-signed Apache certificate so HTTPS can start.

### Flash Policy Server

```env
VC4_FLASH_POLICY_MODE=secure
VC4_FLASH_POLICY_DOMAIN=example.com
VC4_FLASH_POLICY_PORT=1025
```

`VC4_FLASH_POLICY_MODE` accepts:

- `disabled`
- `secure`
- `unsecure`

This writes `/opt/crestron/virtualcontrol/conf/FlashPolicyServer.conf`.

## PAM Authentication

The container installs `mod_authnz_pam` and uses Apache Basic Auth backed by PAM. Instead of requiring real Linux users, PAM calls `vc4-pam-file-auth.sh`, which checks credential files generated at startup from compose variables.

### Admin Interface

Protects `/VirtualControl/config/settings/`:

```env
VC4_PAM_ADMIN_ENABLED=true
VC4_PAM_ADMIN_USERNAME=admin
VC4_PAM_ADMIN_PASSWORD=change-me
```

### Status Interface

Protects `/VirtualControl/config/status/` independently from admin:

```env
VC4_PAM_STATUS_ENABLED=true
VC4_PAM_STATUS_USERNAME=operator
VC4_PAM_STATUS_PASSWORD=change-me-too
```

### Room Interfaces

Create a TOML file, for example `data/hardening/pam-rooms.toml`:

```toml
[default]
username = "default-room-user"
password = "default-room-pass"
targets = ["cws", "html"]

[[rooms]]
id = "a"
username = "roomuser"
password = "roompass"
targets = ["cws", "xpanel", "html"]

[[rooms]]
id = "b"
targets = ["cws", "xpanel", "html"]

[rooms.credentials.cws]
username = "room-b-cws"
password = "cws-password"

[rooms.credentials.xpanel]
username = "room-b-panel"
password = "panel-password"

[rooms.credentials.html]
username = "room-b-html"
password = "html-password"
```

Then set:

```env
VC4_PAM_ROOM_CREDENTIALS_FILE=/run/vc4-hardening/pam-rooms.toml
```

Targets:

- `cws`: `/VirtualControl/Rooms/<room>/cws/`
- `xpanel`: `/VirtualControl/Rooms/<room>/XPanel/Core3XPanel.html`
- `html`: `/VirtualControl/Rooms/<room>/Html/`

Room-level `username` and `password` apply to every listed target. Per-target credentials under `[rooms.credentials.<target>]` override the room-level credentials for that target and allow `cws`, `xpanel`, and `html` to use different logins.

The optional `[default]` block protects rooms that do not have room-specific credentials for the target. For example, if `[default]` includes `cws`, then `/VirtualControl/Rooms/<any-unlisted-room>/cws/` uses the default credential, while rooms with a `cws` credential use their room-specific credential.

Room entries and targets are independent. Each protected room target gets its own PAM service and credential file.

### HTTP vs HTTPS

By default, generated auth blocks include `SSLRequireSSL`:

```env
VC4_PAM_REQUIRE_SSL=true
```

Set `VC4_PAM_REQUIRE_SSL=false` only for local testing.

## Verification Commands

Default boot:

```powershell
docker compose up -d --force-recreate vc4
docker compose exec -T vc4 bash -lc "httpd -t; curl -k -sS -o /dev/null -w '%{http_code}\n' https://127.0.0.1/VirtualControl/config/status/WebApi/DeviceInfo"
```

Admin auth smoke test:

```powershell
$env:VC4_PAM_ADMIN_ENABLED='true'
$env:VC4_PAM_ADMIN_USERNAME='admin'
$env:VC4_PAM_ADMIN_PASSWORD='secret123'
docker compose up -d --force-recreate vc4

docker compose exec -T vc4 bash -lc "curl -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1/VirtualControl/config/settings/"
docker compose exec -T vc4 bash -lc "curl -k -u admin:secret123 -o /dev/null -w '%{http_code}\n' https://127.0.0.1/VirtualControl/config/settings/"
```

Expected: `401` without credentials, `200` with correct credentials.

## Coolify

Use `compose.coolify.yml` as a starting point. The recommended flow is:

1. Build the image somewhere that has access to `vc4/installer/vc4.zip`.
2. Push it to a private registry.
3. Set `VC4_IMAGE` in Coolify to that private image.
4. Add persistent storage for:
   - `/var/lib/mysql`
   - `/opt/crestron`
   - `/var/lib/redis`
   - `/run/vc4-hardening` if using mounted certs or room auth TOML

Do not push the built image to a public registry.
