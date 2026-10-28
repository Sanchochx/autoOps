#!/usr/bin/env bash
# Verifies the controls of US-SYS-001 (read-only). Same variables as 50_os_baseline.sh:
#
#   sudo [TIMEZONE=UTC] [AUTO_REBOOT_TIME=HH:MM] [EXPECTED_TCP_PORTS="8000 3000"] ./scripts/provision/checks/50_os_baseline.sh
#
# EXPECTED_TCP_PORTS: extra TCP ports that may listen on non-loopback interfaces. Always allowed besides
# SSH: the proxy's web ports (resolve_web_ports: UFW_WEB_PORTS or PROXY_HTTP_PORT / PROXY_HTTPS_PORT).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ufw_rules.sh"

require_root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TIMEZONE="${TIMEZONE:-UTC}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-}"
EXTRA_PACKAGES="${EXTRA_PACKAGES-git htop tree}"
DISABLE_SERVICES="${DISABLE_SERVICES-avahi-daemon cups cups-browsed rpcbind bluetooth ModemManager}"
EXPECTED_TCP_PORTS="${EXPECTED_TCP_PORTS:-}"
WEB_PORTS="$(resolve_web_ports)"
SSH_PORT="$(resolve_ssh_port)"
SYSCTL_DST=/etc/sysctl.d/99-autoops.conf
UU_CONF=/etc/apt/apt.conf.d/52autoops-unattended-upgrades

pkgs_installed() { local p; for p in ca-certificates curl gnupg jq chrony unattended-upgrades $EXTRA_PACKAGES; do dpkg -s "$p" >/dev/null 2>&1 || return 1; done; }
svc_disabled() {
  local svc unit
  for svc in $DISABLE_SERVICES; do
    for unit in "${svc}.service" "${svc}.socket"; do
      ! systemctl is-enabled --quiet "$unit" 2>/dev/null && ! systemctl is-active --quiet "$unit" 2>/dev/null || return 1
    done
  done
}
# TCP listeners outside loopback other than SSH, the web ports and EXPECTED_TCP_PORTS.
no_extra_listeners() {
  local listeners addr port allowed=" ${SSH_PORT} ${WEB_PORTS} ${EXPECTED_TCP_PORTS} "
  listeners="$(ss -H -ltn | awk '{print $4}')"
  while read -r addr; do
    [[ -z $addr ]] && continue
    case $addr in 127.*|\[::1\]*) continue ;; esac
    port="${addr##*:}"
    [[ $allowed == *" ${port} "* ]] || { echo "puerto inesperado: ${addr}" >&2; return 1; }
  done <<<"$listeners"
}
uu_dryrun()      { unattended-upgrade --dry-run; }
uu_timer()       { systemctl is-enabled --quiet apt-daily-upgrade.timer && systemctl is-active --quiet apt-daily-upgrade.timer; }
uu_periodic()    { grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; }
uu_sec_only()    { grep -q -- '-security' "$UU_CONF" && ! grep -Eq '"[^"]*-(updates|proposed|backports)"' "$UU_CONF"; }
uu_reboot() {
  if [[ -n $AUTO_REBOOT_TIME ]]; then
    grep -q 'Automatic-Reboot "true"' "$UU_CONF" && grep -q "Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\"" "$UU_CONF"
  else
    grep -q 'Automatic-Reboot "false"' "$UU_CONF"
  fi
}
chrony_active()  { systemctl is-active --quiet chrony; }
chrony_synced()  { chronyc tracking | grep -q 'Leap status *: Normal'; }
tz_ok()          { [[ "$(timedatectl show -p Timezone --value)" == "$TIMEZONE" ]]; }
sysctl_file()    { cmp -s "${REPO_ROOT}/infra/sysctl/99-autoops.conf" "$SYSCTL_DST"; }
# Only counts a real assignment (not comment text): `[-]net.ipv4.ip_forward =`.
no_ip_forward()  { ! grep -Eq '^[[:space:]]*-?net\.ipv4\.(conf\.[^.]+\.)?(ip_)?forward(ing)?[[:space:]]*=' "$SYSCTL_DST"; }
sysctl_values() {
  local line key value actual rc=0
  while IFS= read -r line; do
    [[ $line =~ ^-?([a-z0-9._]+)[[:space:]]*=[[:space:]]*(.+)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    actual="$(sysctl -n "$key" 2>/dev/null)" || { [[ $line == -* ]] && continue; echo "falta ${key}" >&2; rc=1; continue; }
    [[ $actual == "$value" ]] || { echo "${key}: esperado ${value}, actual ${actual}" >&2; rc=1; }
  done <"$SYSCTL_DST"
  return $rc
}

check "paquetes base instalados" pkgs_installed
check "servicios innecesarios deshabilitados" svc_disabled
check "solo SSH (${SSH_PORT}) y web (${WEB_PORTS})${EXPECTED_TCP_PORTS:+ y ${EXPECTED_TCP_PORTS}} escuchan fuera de loopback" no_extra_listeners
check "unattended-upgrade --dry-run funciona" uu_dryrun
check "apt-daily-upgrade.timer activo" uu_timer
check "actualización automática periódica habilitada" uu_periodic
check "unattended-upgrades solo en el canal de seguridad" uu_sec_only
check "política de reinicio automático acorde a AUTO_REBOOT_TIME" uu_reboot
check "chrony activo" chrony_active
check "chrony sincronizado (Leap status: Normal)" chrony_synced
check "zona horaria ${TIMEZONE}" tz_ok
check "99-autoops.conf coincide con infra/sysctl" sysctl_file
check "sysctl no toca ip_forward (Docker lo necesita)" no_ip_forward
check "valores sysctl efectivos = esperados" sysctl_values

check_finish
