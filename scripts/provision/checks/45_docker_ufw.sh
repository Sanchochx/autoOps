#!/usr/bin/env bash
# Verifies the controls of US-NET-002 (read-only). Same variables as 45_docker_ufw.sh:
#
#   sudo [DOCKER_EXT_IFACES=...] [DOCKER_PUBLIC_PORTS="..."] [APP_ENV_FILE=<.env>] ./scripts/provision/checks/45_docker_ufw.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/docker_ufw_rules.sh"

require_root
IFACES="$(resolve_ext_ifaces)"
PORTS="$(resolve_public_ports)"
EXPECTED="$(render_docker_user_block "$IFACES" "$PORTS")"

ufw_active()      { [[ "$(ufw status)" == "Status: active"* ]]; }
ufw_boot()        { grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf && systemctl is-enabled --quiet ufw; }
block_persisted() { [[ "$(current_block "$AFTER_RULES")" == "$EXPECTED" ]]; }
# iptables prints ESTABLISHED,RELATED reversed and may omit --ctdir ORIGINAL (it is the default).
normalize_rules() { sed -e 's/RELATED,ESTABLISHED/ESTABLISHED,RELATED/' -e 's/ --ctdir ORIGINAL//'; }
# Live rules = those of the block (in order), without the chain declaration or comments.
live_matches() {
  local live want
  live="$(iptables -S DOCKER-USER | grep '^-A ')"
  want="$(grep '^-A ' <<<"$EXPECTED")"
  [[ "$(normalize_rules <<<"$live")" == "$(normalize_rules <<<"$want")" ]]
}
forward_jumps()   { iptables -S FORWARD | grep -qE '^-A FORWARD -j DOCKER-USER$'; }
user_first()      { [[ "$(iptables -S FORWARD | grep -E '^-A FORWARD' | head -n1)" == '-A FORWARD -j DOCKER-USER' ]]; }
iptables_managed(){ ! jq -e '.iptables == false' /etc/docker/daemon.json >/dev/null 2>&1; }
no_ext_leak() {
  local iface
  for iface in $IFACES; do iptables -S DOCKER-USER | grep -qE -- "^-A DOCKER-USER -i ${iface} -j DROP$" || return 1; done
}

check "UFW activo" ufw_active
check "UFW habilitado en el arranque" ufw_boot
check "bloque DOCKER-USER persistido en ${AFTER_RULES} = esperado" block_persisted
check "FORWARD salta a DOCKER-USER" forward_jumps
check "DOCKER-USER es la primera regla de FORWARD" user_first
check "reglas vivas de DOCKER-USER = esperadas" live_matches
check "descarte final por interfaz externa (${IFACES})" no_ext_leak
check "Docker conserva la gestión de iptables" iptables_managed

log_info "Interfaces externas: ${IFACES}. Puertos públicos: ${PORTS:-ninguno}."
log_info "Persistencia tras reinicio: reinicia la VM y repite este check; el escaneo nmap externo es manual (README)."
check_finish
