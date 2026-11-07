# Managed by scripts/provision/70_systemd.sh (rendered from infra/systemd/autoops.service.tpl).
# Placeholders: @@APP_DIR@@ and @@SERVICE_USER@@. Do not edit /etc/systemd/system/autoops.service by hand.
[Unit]
Description=AutoOps stack (Docker Compose)
Documentation=file:@@APP_DIR@@/infra/systemd/README.md
Requires=docker.service
Wants=network-online.target
# ufw.service: DOCKER-USER rules (US-NET-002) must be loaded before containers publish ports.
After=docker.service network-online.target ufw.service
# Fail loudly (instead of silently skipping) if the deployment is incomplete.
AssertPathExists=@@APP_DIR@@/docker-compose.yml
AssertPathExists=@@APP_DIR@@/.env

[Service]
Type=oneshot
RemainAfterExit=yes
User=@@SERVICE_USER@@
# `docker` is a supplementary group of the service user (the only member, see US-SYS-002).
WorkingDirectory=@@APP_DIR@@
# Not secrets: the CLI cannot use ~ under ProtectHome, so its config dir lives in the app dir.
# Secrets stay in @@APP_DIR@@/.env (0600), which `docker compose` reads itself from WorkingDirectory.
Environment=DOCKER_CONFIG=@@APP_DIR@@/.docker
Environment=DOCKER_CLI_HINTS=false

# Refuses to start in production with default DB_PASSWORD / JWT_SECRET.
ExecStartPre=@@APP_DIR@@/scripts/ops/validate_env.sh
# --wait blocks until every service is running/healthy, so `systemctl start` only succeeds on a healthy stack.
ExecStart=/usr/bin/docker compose up -d --wait --wait-timeout 240 --remove-orphans
ExecReload=/usr/bin/docker compose up -d --wait --wait-timeout 240 --remove-orphans
# No `-v`: named volumes (postgres_data) survive stop/restart.
ExecStop=/usr/bin/docker compose down
# 240 s healthcheck wait (start_period 15 s + 5 retries x 10 s, plus image pulls/builds) + margin.
TimeoutStartSec=300
TimeoutStopSec=120

# --- Sandboxing (applies to the compose CLI; containers are children of dockerd, see README) ---
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=@@APP_DIR@@
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
# The CLI only talks to /var/run/docker.sock.
RestrictAddressFamilies=AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
