#!/usr/bin/env bash
# Verifies the controls of US-HOST-003 (read-only). Same variables as 30_fail2ban.sh:
#
#   sudo FAIL2BAN_IGNOREIP="<IP/CIDR admin> <local network>" ./scripts/provision/checks/30_fail2ban.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_var FAIL2BAN_IGNOREIP
JAIL_CONF=/etc/fail2ban/jail.d/autoops.local
MAXRETRY="${FAIL2BAN_MAXRETRY:-3}"

f2b_active()    { systemctl is-active --quiet fail2ban; }
f2b_enabled()   { systemctl is-enabled --quiet fail2ban; }
jail_loaded()   { fail2ban-client status sshd; }
conf_has()      { grep -Eq "$1" "$JAIL_CONF"; }
jail_get()      { fail2ban-client get sshd "$1"; }
maxretry_ok()   { [[ "$(jail_get maxretry)" == "$MAXRETRY" ]]; }
# fail2ban lists networks normalized (127.0.0.1/8 -> 127.0.0.0/8; hosts without /32),
# so each entry is normalized the same way before looking it up in `get sshd ignoreip`.
normalize_net() {
  python3 -I -c '
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1], strict=False)
print(n.network_address if n.prefixlen == n.max_prefixlen else n)
' "$1"
}
ignoreip_has() {
  local wanted
  wanted="$(normalize_net "$1")" || return 1
  jail_get ignoreip | grep -qE "(^|[[:space:]])${wanted//./\\.}\$"
}
ignoreip_ok() {
  local ip
  for ip in ${FAIL2BAN_IGNOREIP//,/ }; do ignoreip_has "$ip" || return 1; done
}
loopback_ok()   { ignoreip_has 127.0.0.1/8; }
action_ok()     { jail_get actions | grep -Eq '^(ufw|nftables|iptables)'; }
action_ufw()    { jail_get actions | grep -q '^ufw'; }
syslog_target() { fail2ban-client get logtarget | grep -qx '.*SYSLOG'; }
no_logpath()    { ! grep -Eq '^[[:space:]]*logpath' "$JAIL_CONF"; }

check "fail2ban-client validates the configuration" fail2ban-client -t
check "the fail2ban service is active" f2b_active
check "the fail2ban service starts at boot" f2b_enabled
check "the sshd jail is loaded" jail_loaded
check "jail leyendo de journald (backend = systemd)" conf_has '^backend[[:space:]]*=[[:space:]]*systemd$'
check "no logpath: no log files are read" no_logpath
check "maxretry = ${MAXRETRY}" maxretry_ok
check "ban progresivo (bantime.increment = true)" conf_has '^bantime\.increment[[:space:]]*=[[:space:]]*true$'
check "ignoreip contiene ${FAIL2BAN_IGNOREIP}" ignoreip_ok
check "ignoreip contains the loopback" loopback_ok
check "ban action configured (ufw/nftables/iptables)" action_ok
check "logs de fail2ban a syslog/journald (sin /var/log/fail2ban.log)" syslog_target

if command -v ufw >/dev/null 2>&1; then
  check "UFW installed: the jail bans via ufw" action_ufw
else
  log_info "UFW not installed: skipping the banaction=ufw check (required after US-NET-001)."
fi

check_finish
