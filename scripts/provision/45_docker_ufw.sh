#!/usr/bin/env bash
# US-NET-002: ports published by Docker respect the host firewall. Idempotent.
#
#   sudo ./scripts/provision/45_docker_ufw.sh
#
# Variables (all optional):
#   DOCKER_EXT_IFACES     external interfaces, space-separated; default: those of the default route
#   DOCKER_PUBLIC_PORTS   extra host ports reachable from outside (default: none)
#   APP_ENV_FILE          deployment .env (default ${APP_DIR:-/opt/autoops}/.env)
#   UFW_WEB_PORTS         web ports always allowed; default: PROXY_HTTP_PORT and PROXY_HTTPS_PORT from
#                         APP_ENV_FILE (same resolution as 40_ufw.sh, so UFW and DOCKER-USER agree)
#   DOCKER_UFW_DRY_RUN=1  prints the block and exits without changing anything
#
# Inserts a managed block into /etc/ufw/after.rules (DOCKER-USER chain). Before reloading UFW it
# validates the syntax with iptables-restore --test and saves a backup; if the reload fails, it restores.
# See infra/firewall/README.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/lib/docker_ufw_rules.sh"

require_root
command -v ufw >/dev/null 2>&1 || die "UFW no está instalado (ejecuta antes 40_ufw.sh)."
command -v docker >/dev/null 2>&1 || die "Docker no está instalado (ejecuta antes 60_docker.sh)."
[[ -f $AFTER_RULES ]] || die "No existe ${AFTER_RULES}."
[[ -f $DOCKER_USER_TPL ]] || die "No existe la plantilla ${DOCKER_USER_TPL}."

IFACES="$(resolve_ext_ifaces)"
PORTS="$(resolve_public_ports)"
[[ -n $PORTS ]] || log_warn "Sin puertos públicos: todo el tráfico externo hacia contenedores quedará descartado."
BLOCK="$(render_docker_user_block "$IFACES" "$PORTS")"

if [[ ${DOCKER_UFW_DRY_RUN:-0} == 1 ]]; then
  log_info "DRY RUN: interfaces externas='${IFACES}' puertos públicos='${PORTS}'. Bloque a instalar:"
  printf '%s\n' "$BLOCK"
  exit 0
fi

# Syntax of the isolated block (does not touch the kernel).
printf '*filter\n%s\nCOMMIT\n' "$BLOCK" | iptables-restore --test --noflush \
  || die "El bloque DOCKER-USER generado no es válido para iptables-restore."

if [[ "$(current_block "$AFTER_RULES")" == "$BLOCK" ]]; then
  log_info "Bloque DOCKER-USER ya está al día en ${AFTER_RULES}."
else
  backup="${AFTER_RULES}.autoops.bak"
  cp -p "$AFTER_RULES" "$backup"
  insert_block "$AFTER_RULES" "$BLOCK"
  log_change "bloque DOCKER-USER escrito en ${AFTER_RULES} (copia: ${backup})"
  if [[ "$(ufw status)" == "Status: active"* ]]; then
    if ! ufw reload >/dev/null; then
      cp -p "$backup" "$AFTER_RULES"
      ufw reload >/dev/null || true
      die "ufw reload falló; se restauró ${AFTER_RULES}."
    fi
    log_change "UFW recargado"
  else
    log_warn "UFW inactivo: las reglas se aplicarán al habilitarlo (40_ufw.sh)."
  fi
fi

systemctl is-active --quiet docker || { systemctl start docker && log_change "docker iniciado"; }
iptables -S DOCKER-USER
log_info "45_docker_ufw.sh finalizado. Valida desde OTRA máquina (infra/firewall/README.md)."
