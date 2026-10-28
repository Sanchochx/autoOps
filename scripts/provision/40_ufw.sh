#!/usr/bin/env bash
# US-NET-001: UFW firewall with a deny-by-default policy. Idempotent.
#
#   sudo ./scripts/provision/40_ufw.sh
#
# Variables (all optional):
#   SSH_PORT       SSH port to allow; default: sshd's effective port (`sshd -T`)
#   ADMIN_CIDR     restricts SSH to this IP/CIDR; empty = SSH open to any source (rate limited)
#   UFW_WEB_PORTS  web TCP ports to open, space-separated; default: PROXY_HTTP_PORT and PROXY_HTTPS_PORT
#                  from APP_ENV_FILE (${APP_DIR:-/opt/autoops}/.env), i.e. what Traefik publishes (80 / 443)
#   APP_ENV_FILE   deployment .env read for the proxy ports
#   UFW_DRY_RUN=1  shows the rules it would apply and exits without touching the firewall
#
# ANTI-LOCKOUT SAFETY: the SSH rule is added and verified BEFORE enabling UFW,
# and the script refuses to enable it if sshd is not listening on the given port.
# UFW does not filter ports published by Docker (resolved in US-NET-002).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/ufw_rules.sh"

require_root
ADMIN_CIDR="${ADMIN_CIDR:-}"
validate_ufw_inputs
UFW_WEB_PORTS="$(resolve_web_ports)"
SSH_PORT="$(resolve_ssh_port)"

# --- Anti-lockout guards (before touching anything) ---------------------------------
[[ -n "$(ss -H -ltn "sport = :${SSH_PORT}")" ]] \
  || die "Nada escucha en el puerto ${SSH_PORT}: habilitar UFW cortaría el acceso. Revisa SSH_PORT."
if [[ -n $ADMIN_CIDR && -n ${SSH_CONNECTION:-} ]]; then
  client_ip="${SSH_CONNECTION%% *}"
  python3 -I -c '
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
' "$client_ip" "$ADMIN_CIDR" \
    || die "Tu sesión SSH actual (${client_ip}) no está en ADMIN_CIDR=${ADMIN_CIDR}: te quedarías sin acceso nuevo."
fi

mapfile -t wanted < <(expected_ufw_rules "$SSH_PORT" "$ADMIN_CIDR" $UFW_WEB_PORTS)
if [[ ${UFW_DRY_RUN:-0} == 1 ]]; then
  log_info "DRY RUN: se aplicaría deny incoming / allow outgoing / deny routed, logging low y:"
  printf '  %s\n' "${wanted[@]}"
  exit 0
fi

# --- Installation ------------------------------------------------------------------
if ! command -v ufw >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ufw
  log_change "instalado ufw"
fi

was_active=0
[[ "$(ufw status)" == "Status: active"* ]] && was_active=1
before="$(added_ufw_rules | sort)"

# --- AC-1: default policies and SSH (BEFORE enabling) --------------------------
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null

if [[ -n $ADMIN_CIDR ]]; then
  ufw limit from "$ADMIN_CIDR" to any port "$SSH_PORT" proto tcp comment 'autoops: ssh' >/dev/null
else
  ufw limit "${SSH_PORT}/tcp" comment 'autoops: ssh' >/dev/null
fi

# --- AC-2: web ports (the proxy's, by default) ---------------------------------
for port in $UFW_WEB_PORTS; do
  ufw allow "${port}/tcp" comment 'autoops: web' >/dev/null
done

# --- AC-3: logging to journald/kernel ----------------------------------------------------
ufw logging low >/dev/null

# Verify the SSH rule exists before enabling; otherwise abort.
added_now="$(added_ufw_rules)"
grep -qxF "${wanted[0]}" <<<"$added_now" \
  || die "La regla SSH '${wanted[0]}' no quedó registrada; UFW NO se habilita para no bloquearte."

if ((!was_active)); then
  ufw --force enable >/dev/null
  log_change "UFW habilitado (SSH ${SSH_PORT}/tcp ya permitido)"
fi
[[ -d /run/systemd/system ]] && systemctl enable ufw >/dev/null 2>&1 || true

after="$(added_ufw_rules | sort)"
[[ $before == "$after" ]] || log_change "reglas UFW actualizadas"

if [[ -z $ADMIN_CIDR ]]; then
  log_warn "SSH abierto a cualquier origen (con rate limit). Define ADMIN_CIDR para restringirlo."
fi
log_warn "UFW no filtra puertos publicados por Docker (US-NET-002). Si ya usas banaction=nftables, vuelve a ejecutar 30_fail2ban.sh para pasar a 'ufw'."
ufw status verbose
log_info "40_ufw.sh finalizado."
