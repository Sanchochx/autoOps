# Managed by scripts/provision/70_systemd.sh (rendered from infra/systemd/autoops-deploy.service.tpl).
# Started only by autoops-deploy.path when the runner leaves a request; manual: `sudo systemctl start autoops-deploy`.
# No [Install] section on purpose. Type=oneshot: systemd never runs two deploys at once.
[Unit]
Description=AutoOps deploy (request handed over by the runner)
Documentation=file:@@APP_DIR@@/infra/systemd/README.md
Requires=docker.service
After=docker.service network-online.target autoops.service
Wants=network-online.target
AssertPathExists=@@APP_DIR@@/docker-compose.yml
AssertPathExists=@@APP_DIR@@/.env
AssertPathExists=@@DEPLOY_INBOX_DIR@@
AssertPathExists=@@DEPLOY_OUTBOX_DIR@@

[Service]
Type=oneshot
User=@@SERVICE_USER@@
WorkingDirectory=@@APP_DIR@@
Environment=APP_DIR=@@APP_DIR@@
Environment=DOCKER_CONFIG=@@APP_DIR@@/.docker
Environment=DOCKER_CLI_HINTS=false
# The request is untrusted input: deploy.sh reads only `tag` and `run_id` from it and rejects anything else.
# Settings (DEPLOY_*, IMAGE_REPOSITORY, DOMAIN...) come from .env (0600); nothing secret in the unit.
ExecStart=@@APP_DIR@@/scripts/ops/deploy.sh --request-file @@DEPLOY_INBOX_DIR@@/request
# pull + backup + migrate + up --wait (240 s) + probe + a possible rollback (another 240 s) + margin.
TimeoutStartSec=1800

# --- Sandboxing (same style as autoops.service; the network is needed for the GitHub API, the registry and the probe) ---
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=@@APP_DIR@@ @@BACKUP_DIR@@ @@DEPLOY_INBOX_DIR@@ @@DEPLOY_OUTBOX_DIR@@
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
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077
