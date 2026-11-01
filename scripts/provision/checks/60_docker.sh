#!/usr/bin/env bash
# Verifies the controls of US-SYS-002 (read-only). Same variables as 60_docker.sh:
#
#   sudo ./scripts/provision/checks/60_docker.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICE_USER="${SERVICE_USER:-autoops}"
DAEMON_DST=/etc/docker/daemon.json
SOURCES=/etc/apt/sources.list.d/docker.sources
KEYRING=/etc/apt/keyrings/docker.asc
FPR="${DOCKER_GPG_FINGERPRINT:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
FPR="${FPR// /}"

pkgs_installed() { local p; for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do dpkg -s "$p" >/dev/null 2>&1 || return 1; done; }
repo_signed()    { grep -q "^Signed-By: ${KEYRING}\$" "$SOURCES" && [[ "$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')" == "${FPR^^}" ]]; }
svc_ok()         { systemctl is-enabled --quiet "$1" && systemctl is-active --quiet "$1"; }
daemon_matches() { cmp -s "${REPO_ROOT}/infra/docker/daemon.json" "$DAEMON_DST"; }
daemon_key()     { jq -e "$1" "$DAEMON_DST"; }
info_is()        { [[ "$(docker info --format "$1")" == "$2" ]]; }
no_hosts_key()   { ! jq -e 'has("hosts")' "$DAEMON_DST"; }
iptables_managed() { jq -e '(.iptables // true) == true' "$DAEMON_DST"; }
no_tcp_daemon()  { [[ -z "$(ss -H -ltn '( sport = :2375 or sport = :2376 )')" ]]; }
socket_perms()   { [[ "$(stat -c '%U:%G %a' /var/run/docker.sock)" == "root:docker 660" ]]; }
docker_members() { getent group docker | cut -d: -f4; }
only_service_user() { local m; m="$(docker_members)"; [[ -z $m || $m == "$SERVICE_USER" ]]; }
service_in_group()  { in_group "$SERVICE_USER" docker; }

check "paquetes de Docker instalados (engine, cli, containerd, buildx, compose)" pkgs_installed
check "official repository with Signed-By and verified key fingerprint" repo_signed
check "docker version (cliente y servidor)" docker version
check "docker compose version" docker compose version
check "servicio docker activo y habilitado" svc_ok docker
check "servicio containerd activo y habilitado" svc_ok containerd
check "daemon.json matches infra/docker/daemon.json" daemon_matches
check "no-new-privileges = true" daemon_key '.["no-new-privileges"] == true'
check "userland-proxy = false" daemon_key '.["userland-proxy"] == false'
check "log-driver json-file con max-size y max-file" daemon_key '.["log-driver"] == "json-file" and (.["log-opts"]["max-size"] != null) and (.["log-opts"]["max-file"] != null)'
check "docker info: Logging Driver = json-file" info_is '{{.LoggingDriver}}' json-file
check "docker info: Live Restore habilitado" info_is '{{.LiveRestoreEnabled}}' true
check "iptables managed by Docker (not disabled)" iptables_managed
check "no 'hosts' in daemon.json (no TCP exposure)" no_hosts_key
check "the daemon does not listen on 2375/2376" no_tcp_daemon
check "socket /var/run/docker.sock root:docker 660" socket_perms
check "${SERVICE_USER} is in the docker group" service_in_group
check "the docker group only contains ${SERVICE_USER}" only_service_user

check_finish
