# Managed by scripts/provision/75_runner.sh (rendered from infra/systemd/autoops-runner.service.tpl).
# Placeholders: @@APP_DIR@@ and @@SERVICE_USER@@. Do not edit /etc/systemd/system/autoops-runner.service by hand.
# The self-hosted runner (US-CICD-003) is a Compose project of its own, so autoops.service (`up --remove-orphans`,
# `down`) never touches it and a runner failure never touches the stack.
[Unit]
Description=AutoOps self-hosted GitHub Actions runner (Docker Compose)
Documentation=file:@@APP_DIR@@/infra/runner/README.md
Requires=docker.service
Wants=network-online.target
After=docker.service network-online.target ufw.service
# Fail loudly (instead of silently skipping) if the deployment is incomplete.
AssertPathExists=@@APP_DIR@@/infra/runner/docker-compose.yml
AssertPathExists=@@APP_DIR@@/.env

[Service]
# Foreground `up`: the runner's output goes to the journal and the unit restarts whenever the container stops.
Type=simple
User=@@SERVICE_USER@@
WorkingDirectory=@@APP_DIR@@/infra/runner
# Not secrets: the CLI cannot use ~ under ProtectHome, so its config dir lives in the app dir.
Environment=DOCKER_CONFIG=@@APP_DIR@@/.docker
Environment=DOCKER_CLI_HINTS=false
# The registration token is only needed once, by 75_runner.sh; afterwards the runner keeps its own credentials in
# its volume. Empty here (it wins over .env) so the service never mounts, and never needs, the token file.
Environment=RUNNER_REGISTRATION_TOKEN_FILE=

# The image is built by 75_runner.sh (--no-build); the settings (RUNNER_*) come from the same .env as the stack.
ExecStart=/usr/bin/docker compose -f @@APP_DIR@@/infra/runner/docker-compose.yml --env-file @@APP_DIR@@/.env up --no-build --abort-on-container-exit --no-color --no-log-prefix
# No `-v`: the credentials volume survives restarts (otherwise every restart would need a new token).
ExecStop=/usr/bin/docker compose -f @@APP_DIR@@/infra/runner/docker-compose.yml --env-file @@APP_DIR@@/.env down
Restart=always
RestartSec=30
# stop_grace_period of the container is 30 s.
TimeoutStopSec=90

# --- Sandboxing (applies to the compose CLI; the container is a child of dockerd) ---
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
