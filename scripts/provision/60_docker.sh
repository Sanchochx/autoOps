#!/usr/bin/env bash
# US-SYS-002: Docker Engine + Compose from the official repository and hardened daemon.json. Idempotent.
#
#   sudo ./scripts/provision/60_docker.sh
#
# Variables (all optional):
#   DOCKER_VERSION               apt version of docker-ce and docker-ce-cli (e.g. 5:27.3.1-1~ubuntu.24.04~noble);
#                                empty = latest in the repository
#   DOCKER_CONTAINERD_VERSION    same for containerd.io
#   DOCKER_COMPOSE_VERSION       same for docker-compose-plugin
#   DOCKER_BUILDX_VERSION        same for docker-buildx-plugin
#   DOCKER_APT_SUITE             repository suite (default: VERSION_CODENAME from /etc/os-release)
#   DOCKER_GPG_FINGERPRINT       expected fingerprint of Docker's key (default: the official one)
#   SERVICE_USER=autoops         only user that belongs to the docker group
# See infra/docker/README.md. The firewall (Docker <-> UFW) is resolved in US-NET-002.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DAEMON_SRC="${REPO_ROOT}/infra/docker/daemon.json"
DAEMON_DST=/etc/docker/daemon.json
KEYRING=/etc/apt/keyrings/docker.asc
SOURCES=/etc/apt/sources.list.d/docker.sources
DOCKER_URL=https://download.docker.com/linux/ubuntu

require_root
SERVICE_USER="${SERVICE_USER:-autoops}"
DOCKER_GPG_FINGERPRINT="${DOCKER_GPG_FINGERPRINT:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
DOCKER_GPG_FINGERPRINT="${DOCKER_GPG_FINGERPRINT// /}"
DOCKER_APT_SUITE="${DOCKER_APT_SUITE:-$(. /etc/os-release && echo "${VERSION_CODENAME:-}")}"
declare -A PIN=(
  [docker-ce]="${DOCKER_VERSION:-}" [docker-ce-cli]="${DOCKER_VERSION:-}"
  [containerd.io]="${DOCKER_CONTAINERD_VERSION:-}"
  [docker-compose-plugin]="${DOCKER_COMPOSE_VERSION:-}" [docker-buildx-plugin]="${DOCKER_BUILDX_VERSION:-}"
)
PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

[[ -n $DOCKER_APT_SUITE ]] || die "Could not determine the suite; set DOCKER_APT_SUITE."
[[ $DOCKER_GPG_FINGERPRINT =~ ^[0-9A-Fa-f]{40}$ ]] || die "Invalid DOCKER_GPG_FINGERPRINT (40 hex characters)."
[[ $(. /etc/os-release && echo "$ID") == ubuntu ]] || die "Este script soporta Ubuntu (repositorio ${DOCKER_URL})."
id "$SERVICE_USER" >/dev/null 2>&1 || die "User ${SERVICE_USER} does not exist (run 10_users.sh first)."
jq empty "$DAEMON_SRC" || die "${DAEMON_SRC} is not valid JSON."
if jq -e 'has("hosts") or (.iptables == false)' "$DAEMON_SRC" >/dev/null; then
  die "daemon.json must not define 'hosts' (no TCP exposure) nor disable iptables."
fi
has_systemd() { [[ -d /run/systemd/system ]]; }
export DEBIAN_FRONTEND=noninteractive

# Packages that conflict with docker-ce: not removed automatically (they may hold containers/data).
for conflict in docker.io docker-doc docker-compose podman-docker; do
  ! dpkg -s "$conflict" >/dev/null 2>&1 || die "'${conflict}' is installed and conflicts with docker-ce. Remove it manually (sudo apt-get remove ${conflict}) and retry."
done

# --- AC-1: official repository with verified key ----------------------------------
install -d -m 755 /etc/apt/keyrings
key_fpr() { gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'; }
if [[ ! -f $KEYRING ]] || [[ "$(key_fpr "$KEYRING")" != "${DOCKER_GPG_FINGERPRINT^^}" ]]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL "${DOCKER_URL}/gpg" -o "$tmp"
  [[ "$(key_fpr "$tmp")" == "${DOCKER_GPG_FINGERPRINT^^}" ]] \
    || die "The fingerprint of the downloaded key does not match DOCKER_GPG_FINGERPRINT: not installing."
  install -m 644 -o root -g root "$tmp" "$KEYRING"
  log_change "installed and verified the Docker GPG key in ${KEYRING}"
fi

arch="$(dpkg --print-architecture)"
ensure_file "$SOURCES" "Types: deb
URIs: ${DOCKER_URL}
Suites: ${DOCKER_APT_SUITE}
Components: stable
Architectures: ${arch}
Signed-By: ${KEYRING}"
chmod 644 "$SOURCES"
policy="$(apt-cache policy docker-ce 2>/dev/null || true)"
if ((FILE_CHANGED)) || [[ $policy != *download.docker.com* ]]; then
  apt-get update -qq || { rm -f "$SOURCES"; die "apt update failed with suite '${DOCKER_APT_SUITE}'; does it exist in ${DOCKER_URL}/dists/? (set DOCKER_APT_SUITE)."; }
fi

docker_preinstalled=0
dpkg -s docker-ce >/dev/null 2>&1 && docker_preinstalled=1

# --- AC-2: daemon.json BEFORE installing (the first start is already hardened) -------
install -d -m 755 /etc/docker
DAEMON_CHANGED=0
if [[ ! -f $DAEMON_DST ]] || ! cmp -s "$DAEMON_SRC" "$DAEMON_DST"; then
  [[ -f $DAEMON_DST ]] && cp -p "$DAEMON_DST" "${DAEMON_DST}.autoops-prev"
  install -m 644 -o root -g root "$DAEMON_SRC" "$DAEMON_DST"
  DAEMON_CHANGED=1
  log_change "escrito ${DAEMON_DST}"
fi

# --- AC-1: installation (only what is missing or differs from the pinned version) ----------------
to_install=()
for pkg in "${PACKAGES[@]}"; do
  want="${PIN[$pkg]}"
  have="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  if [[ -z $have ]]; then
    to_install+=("${pkg}${want:+=$want}")
  elif [[ -n $want && $have != "$want" ]]; then
    to_install+=("${pkg}=${want}")
  fi
done
if ((${#to_install[@]} > 0)); then
  apt-get install -y -qq --allow-downgrades "${to_install[@]}"
  log_change "instalados: ${to_install[*]}"
fi

# --- AC-2: validate and, if the daemon was already running with another config, restart it -----------------
if ((DAEMON_CHANGED)); then
  if ! dockerd --validate --config-file="$DAEMON_DST" >/dev/null 2>&1; then
    dockerd --validate --config-file="$DAEMON_DST" >&2 || true
    if [[ -f ${DAEMON_DST}.autoops-prev ]]; then mv -f "${DAEMON_DST}.autoops-prev" "$DAEMON_DST"; else rm -f "$DAEMON_DST"; fi
    die "daemon.json does not pass 'dockerd --validate'; the previous one was restored."
  fi
  rm -f "${DAEMON_DST}.autoops-prev"
fi
if has_systemd; then
  systemctl enable docker containerd >/dev/null 2>&1
  if ! systemctl is-active --quiet docker; then
    systemctl start docker
    log_change "docker iniciado"
  elif ((DAEMON_CHANGED && docker_preinstalled)); then
    systemctl restart docker
    log_change "docker restarted with the new daemon.json (containers without a restart policy are stopped)"
  fi
fi

# --- AC-3: socket access (docker group = root) -----------------------------------------------
getent group docker >/dev/null || groupadd --system docker
in_group "$SERVICE_USER" docker || { usermod -aG docker "$SERVICE_USER"; log_change "${SERVICE_USER} added to the docker group"; }
for member in $(getent group docker | cut -d: -f4 | tr ',' ' '); do
  if [[ $member != "$SERVICE_USER" ]]; then
    gpasswd --delete "$member" docker >/dev/null
    log_change "${member} removed from the docker group (use sudo docker)"
  fi
done

docker version --format 'Docker Engine {{.Server.Version}}'
docker compose version
log_info "60_docker.sh finished."
