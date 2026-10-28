#!/usr/bin/env bash
# Verifies the controls of US-NET-002 (read-only). Same variables as 45_docker_ufw.sh:
#
#   sudo [DOCKER_EXT_IFACES=...] [DOCKER_PUBLIC_PORTS="..."] [APP_ENV_FILE=<.env>] ./scripts/provision/checks/45_docker_ufw.sh
# STACK_REQUIRED=0 skips the check that Traefik is up and publishing the web ports.
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

# --- Published ports (US-PROXY-003): Traefik is the only service that publishes host ports ------------
PROXY_SERVICE=traefik
STACK_REQUIRED="${STACK_REQUIRED:-1}"
WEB_PORTS="$(resolve_web_ports | tr ' ' '\n' | sort -nu | paste -sd' ')"
LEAKS='' UNLISTED='' PROXY_PUBLISHED='' LEGACY_PUBLIC=''
if docker_ps="$(docker ps --format '{{.Label "com.docker.compose.service"}}|{{.Ports}}' 2>/dev/null)"; then
  while IFS='|' read -r service ports; do
    published="$(external_host_ports "$ports" | sort -nu | paste -sd' ')"
    [[ -n $published ]] || continue
    [[ $service == "$PROXY_SERVICE" ]] && PROXY_PUBLISHED="$published" || LEAKS+="${service:-?}:${published// /,} "
    for port in $published; do
      [[ " ${PORTS} " == *" ${port} "* ]] || UNLISTED+="${service:-?}:${port} "
    done
  done <<<"$docker_ps"
fi
for key in PORT FRONTEND_PORT; do
  legacy="$(env_value "${APP_ENV_FILE:-${APP_DIR:-/opt/autoops}/.env}" "$key")"
  [[ -n $legacy && " ${PORTS} " == *" ${legacy} "* && " ${WEB_PORTS} " != *" ${legacy} "* ]] && LEGACY_PUBLIC+="${key}=${legacy} "
done
docker_answers()   { docker ps -q >/dev/null; }
no_other_publish() { [[ -z $LEAKS ]]; }
all_publish_allowed() { [[ -z $UNLISTED ]]; }
proxy_publishes_web() { [[ $PROXY_PUBLISHED == "$WEB_PORTS" ]]; }
legacy_closed()    { [[ -z $LEGACY_PUBLIC ]]; }

check "UFW activo" ufw_active
check "UFW habilitado en el arranque" ufw_boot
check "bloque DOCKER-USER persistido en ${AFTER_RULES} = esperado" block_persisted
check "FORWARD salta a DOCKER-USER" forward_jumps
check "DOCKER-USER es la primera regla de FORWARD" user_first
check "reglas vivas de DOCKER-USER = esperadas" live_matches
check "descarte final por interfaz externa (${IFACES})" no_ext_leak
check "Docker conserva la gestión de iptables" iptables_managed
check "docker ps responde" docker_answers
check "ningún contenedor distinto de ${PROXY_SERVICE} publica puertos en el host" no_other_publish
check "todo puerto publicado está autorizado en DOCKER-USER" all_publish_allowed
check "PORT / FRONTEND_PORT no figuran como públicos" legacy_closed
if [[ $STACK_REQUIRED == 1 ]]; then
  check "${PROXY_SERVICE} publica exactamente los puertos web (${WEB_PORTS})" proxy_publishes_web
fi
[[ -z $LEAKS ]] || log_warn "Puertos publicados por servicios ajenos al proxy: ${LEAKS}"
[[ -z $UNLISTED ]] || log_warn "Puertos publicados sin autorización en DOCKER-USER: ${UNLISTED}"
[[ -z $LEGACY_PUBLIC ]] || log_warn "Puertos legados aún públicos: ${LEGACY_PUBLIC}"

log_info "Interfaces externas: ${IFACES}. Puertos públicos: ${PORTS:-ninguno}."
log_info "Persistencia tras reinicio: reinicia la VM y repite este check; el escaneo nmap externo es manual (README)."
check_finish
