#!/usr/bin/env bash
# Verifies the controls of US-NET-001 (read-only). Same variables as 40_ufw.sh:
#
#   sudo [ADMIN_CIDR=<cidr>] [UFW_WEB_PORTS="80 443"] [APP_ENV_FILE=<.env>] ./scripts/provision/checks/40_ufw.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ufw_rules.sh"

require_root
ADMIN_CIDR="${ADMIN_CIDR:-}"
validate_ufw_inputs
UFW_WEB_PORTS="$(resolve_web_ports)"
SSH_PORT="$(resolve_ssh_port)"

ufw_active()     { [[ "$(ufw status)" == "Status: active"* ]]; }
ufw_boot()       { grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf && systemctl is-enabled --quiet ufw; }
verbose_has()    { [[ "$(ufw status verbose)" == *"$1"* ]]; }
defaults_ok()    { verbose_has 'Default: deny (incoming), allow (outgoing), deny (routed)'; }
logging_ok()     { verbose_has 'Logging: on (low)'; }
ssh_listening()  { [[ -n "$(ss -H -ltn "sport = :${SSH_PORT}")" ]]; }
# Defined rules = exactly the expected ones. The blocks
# `deny from <ip>` that fail2ban inserts when using banaction=ufw are tolerated.
rules_exact() {
  local actual expected
  actual="$(added_ufw_rules | { grep -Ev '^ufw (insert [0-9]+ )?deny from ' || true; } | sort)"
  expected="$(expected_ufw_rules "$SSH_PORT" "$ADMIN_CIDR" $UFW_WEB_PORTS | sort)"
  [[ $actual == "$expected" ]]
}
ssh_rule_ok() {
  local added rule
  added="$(added_ufw_rules)"
  rule="$(expected_ufw_rules "$SSH_PORT" "$ADMIN_CIDR")"
  grep -qxF "$rule" <<<"$added"
}

check "ufw instalado" command -v ufw
check "UFW activo" ufw_active
check "UFW habilitado en el arranque" ufw_boot
check "política por defecto: deny incoming / allow outgoing / deny routed" defaults_ok
check "sshd escucha en ${SSH_PORT}" ssh_listening
check "SSH ${SSH_PORT}/tcp permitido con rate limit${ADMIN_CIDR:+ solo desde ${ADMIN_CIDR}}" ssh_rule_ok
check "reglas definidas = exactamente las esperadas" rules_exact
check "logging low" logging_ok

log_info "Puertos web esperados: ${UFW_WEB_PORTS}."
check_finish
