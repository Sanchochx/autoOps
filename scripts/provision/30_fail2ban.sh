#!/usr/bin/env bash
# US-HOST-003: SSH brute-force protection with fail2ban (journald). Idempotent.
#
#   sudo FAIL2BAN_IGNOREIP="<IP/CIDR admin> <local network>" ./scripts/provision/30_fail2ban.sh
#
# Variables:
#   FAIL2BAN_IGNOREIP        required: IPs/CIDRs that are never banned (separated by spaces or commas)
#   FAIL2BAN_MAXRETRY=3      failed attempts before the ban
#   FAIL2BAN_FINDTIME=10m    window in which attempts are counted
#   FAIL2BAN_BANTIME=1h      duration of the first ban
#   FAIL2BAN_BANTIME_FACTOR=2   multiplier per repeat offense (progressive ban)
#   FAIL2BAN_BANTIME_MAXTIME=1w cap of the progressive ban
#   FAIL2BAN_BANACTION       default `ufw` if UFW is installed; otherwise `nftables`
#   SSH_PORT                 default: sshd's effective port (`sshd -T`)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F2B_INFRA="${REPO_ROOT}/infra/fail2ban"
JAIL_CONF=/etc/fail2ban/jail.d/autoops.local
MAIN_CONF=/etc/fail2ban/fail2ban.local

require_root
require_var FAIL2BAN_IGNOREIP

MAXRETRY="${FAIL2BAN_MAXRETRY:-3}"
FINDTIME="${FAIL2BAN_FINDTIME:-10m}"
BANTIME="${FAIL2BAN_BANTIME:-1h}"
BANTIME_FACTOR="${FAIL2BAN_BANTIME_FACTOR:-2}"
BANTIME_MAXTIME="${FAIL2BAN_BANTIME_MAXTIME:-1w}"

[[ $MAXRETRY =~ ^[1-9][0-9]*$ ]] || die "FAIL2BAN_MAXRETRY must be a positive integer."
[[ $BANTIME_FACTOR =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "FAIL2BAN_BANTIME_FACTOR must be numeric."
for var in FINDTIME BANTIME BANTIME_MAXTIME; do
  [[ ${!var} =~ ^[0-9]+[smhdw]?$ ]] || die "FAIL2BAN_${var} is invalid (e.g. 600, 10m, 1h, 1w)."
done

# ignoreip: normalized to spaces and loopback is always included.
ignoreip_in="${FAIL2BAN_IGNOREIP//,/ }"
[[ $ignoreip_in =~ ^[0-9a-fA-F:./[:space:]]+$ ]] || die "FAIL2BAN_IGNOREIP only accepts IPs/CIDRs separated by spaces or commas."
IGNOREIP="127.0.0.1/8 ::1 $(xargs <<<"$ignoreip_in")"

SSH_PORT="${SSH_PORT:-}"
if [[ -z $SSH_PORT ]]; then
  [[ -x /usr/sbin/sshd ]] || die "openssh-server is not installed and SSH_PORT was not set."
  SSH_PORT="$(/usr/sbin/sshd -T | awk '$1 == "port" { print $2; exit }')"
fi
[[ $SSH_PORT =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || die "Invalid SSH_PORT: '${SSH_PORT}'."

if [[ -n ${FAIL2BAN_BANACTION:-} ]]; then
  BANACTION="$FAIL2BAN_BANACTION"
elif command -v ufw >/dev/null 2>&1; then
  BANACTION=ufw
else
  BANACTION=nftables
fi
[[ $BANACTION =~ ^[a-z0-9_-]+$ ]] || die "Invalid FAIL2BAN_BANACTION."

# --- AC-1: installation ---------------------------------------------------------
if ! dpkg -s fail2ban python3-systemd >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq fail2ban python3-systemd
  log_change "instalados fail2ban y python3-systemd"
fi

# --- AC-1 / AC-2 / AC-3: configuration with validation and rollback -----------
declare -A backup=()
apply_conf() { # apply_conf <target> <content>
  local dest=$1 content=$2
  if [[ -f $dest && "$(cat "$dest")" == "$content" ]]; then
    log_info "${dest} is already up to date."
    return
  fi
  [[ -f $dest ]] && cp -p "$dest" "${dest}.autoops-prev"
  backup[$dest]=1
  ensure_file "$dest" "$content"
}

restore_confs() {
  local dest
  for dest in "${!backup[@]}"; do
    if [[ -f ${dest}.autoops-prev ]]; then mv -f "${dest}.autoops-prev" "$dest"; else rm -f "$dest"; fi
  done
}

install -d -m 755 /etc/fail2ban/jail.d
jail_content="$(sed -e "s|@SSH_PORT@|${SSH_PORT}|" -e "s|@MAXRETRY@|${MAXRETRY}|" \
  -e "s|@FINDTIME@|${FINDTIME}|" -e "s|@BANTIME@|${BANTIME}|" \
  -e "s|@BANTIME_FACTOR@|${BANTIME_FACTOR}|" -e "s|@BANTIME_MAXTIME@|${BANTIME_MAXTIME}|" \
  -e "s|@IGNOREIP@|${IGNOREIP}|" -e "s|@BANACTION@|${BANACTION}|g" \
  "${F2B_INFRA}/autoops.local.tpl")"
apply_conf "$JAIL_CONF" "$jail_content"
apply_conf "$MAIN_CONF" "$(cat "${F2B_INFRA}/fail2ban.local")"
chmod 644 "$JAIL_CONF" "$MAIN_CONF"

if ! fail2ban-client -t >/dev/null 2>&1; then
  fail2ban-client -t >&2 || true
  restore_confs
  die "The fail2ban configuration is not valid (fail2ban-client -t); the previous one was restored."
fi
for dest in "${!backup[@]}"; do rm -f "${dest}.autoops-prev"; done

# --- Service -----------------------------------------------------------------
if [[ -d /run/systemd/system ]]; then
  systemctl enable fail2ban >/dev/null 2>&1
  if ! systemctl is-active --quiet fail2ban; then
    systemctl start fail2ban
    log_change "fail2ban iniciado"
  elif ((${#backup[@]} > 0)); then
    systemctl restart fail2ban
    log_change "fail2ban restarted with the new configuration"
  fi
else
  log_warn "No systemd: could not enable/start fail2ban."
fi

if [[ $BANACTION != ufw ]]; then
  log_warn "banaction=${BANACTION}: UFW is not installed yet. After US-NET-001 run this script again to use 'ufw'."
fi
log_info "30_fail2ban.sh finished (sshd jail: port ${SSH_PORT}, maxretry ${MAXRETRY}, findtime ${FINDTIME}, progressive bantime ${BANTIME}, ban via ${BANACTION})."
