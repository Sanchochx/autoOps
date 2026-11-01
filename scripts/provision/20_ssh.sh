#!/usr/bin/env bash
# US-HOST-002: SSH hardening and key management. Idempotent.
#
#   sudo ADMIN_USER=<user> ADMIN_SSH_PUBKEY_FILE=<path.pub> ./scripts/provision/20_ssh.sh
#   sudo ADMIN_USER=<user> ./scripts/provision/20_ssh.sh --confirm   # after testing the login
#
# If the configuration changes, arms an automatic rollback (SSH_ROLLBACK_MINUTES)
# that is only cancelled with --confirm. See infra/ssh/README.md.
# Optional variables: DEPLOY_USER=autoops-deploy, DEPLOY_SSH_PUBKEY_FILE,
# DEPLOY_ALLOWED_FROM (required if there is a deploy key), SSH_ROLLBACK_MINUTES=5.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_INFRA="${REPO_ROOT}/infra/ssh"
CONF=/etc/ssh/sshd_config.d/10-autoops.conf
BANNER=/etc/ssh/autoops-banner
STATE_DIR=/var/lib/autoops-provision/ssh
ENTRYPOINT=/usr/local/sbin/autoops-deploy-entrypoint
ROLLBACK_BIN=/usr/local/sbin/autoops-ssh-rollback
ROLLBACK_UNIT=autoops-ssh-rollback

require_root
require_var ADMIN_USER
DEPLOY_USER="${DEPLOY_USER:-autoops-deploy}"
DEPLOY_SSH_PUBKEY_FILE="${DEPLOY_SSH_PUBKEY_FILE:-}"
DEPLOY_ALLOWED_FROM="${DEPLOY_ALLOWED_FROM:-}"
SSH_ROLLBACK_MINUTES="${SSH_ROLLBACK_MINUTES:-5}"

has_systemd() { [[ -d /run/systemd/system ]]; }

reload_sshd() {
  if has_systemd && systemctl is-active --quiet ssh; then
    systemctl reload ssh
  fi
}

# --- --confirm mode: cancels the automatic rollback --------------------------
if [[ "${1:-}" == "--confirm" ]]; then
  if has_systemd; then
    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR"
  log_info "Change confirmed: automatic rollback cancelled."
  exit 0
fi
[[ $# -eq 0 ]] || die "Unknown argument '$1' (only --confirm is supported)."

require_var ADMIN_SSH_PUBKEY_FILE
[[ $SSH_ROLLBACK_MINUTES =~ ^[0-9]+$ ]] || die "SSH_ROLLBACK_MINUTES must be an integer."
[[ -x /usr/sbin/sshd ]] || die "openssh-server is not installed."
id "$ADMIN_USER" >/dev/null 2>&1 || die "User ${ADMIN_USER} does not exist (run 10_users.sh first)."
in_group "$ADMIN_USER" sudo || die "${ADMIN_USER} is not in the sudo group: SSH is not hardened without an administration path."
grep -Eq '^Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config does not include sshd_config.d/*.conf."
/usr/sbin/sshd -t || die "The current sshd configuration is already invalid; fix it first."

if [[ -n $DEPLOY_SSH_PUBKEY_FILE ]]; then
  [[ -n $DEPLOY_ALLOWED_FROM ]] || die "DEPLOY_ALLOWED_FROM is required with DEPLOY_SSH_PUBKEY_FILE (from= restriction)."
  [[ $DEPLOY_ALLOWED_FROM =~ ^[0-9a-fA-F:./,]+$ ]] || die "DEPLOY_ALLOWED_FROM only accepts IPs/CIDRs separated by commas."
  [[ $DEPLOY_USER =~ ^[a-z_][a-z0-9_-]*$ && $DEPLOY_USER != "$ADMIN_USER" ]] || die "Invalid DEPLOY_USER."
fi

# read_pubkey <file>: prints the ed25519 public key (one line) or aborts.
read_pubkey() {
  local file=$1 line
  [[ -r $file ]] || die "Cannot read ${file}."
  [[ "$(grep -c . "$file")" == 1 ]] || die "${file} must contain exactly one public key."
  line="$(grep . "$file")"
  [[ $line =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]] \
    || die "${file} is not an ed25519 public key (is it the private key or another type?)."
  ssh-keygen -l -f "$file" >/dev/null || die "${file} is not a valid key."
  printf '%s' "$line"
}

# ensure_ssh_dir <user>: creates ~/.ssh (700) and returns the home via stdout.
ensure_ssh_dir() {
  local user=$1 home
  home="$(getent passwd "$user" | cut -d: -f6)"
  install -d -o "$user" -g "$(id -gn "$user")" -m 700 "${home}/.ssh"
  printf '%s' "$home"
}

# --- AC-1: admin key (added; existing ones are never deleted) --------
admin_key="$(read_pubkey "$ADMIN_SSH_PUBKEY_FILE")"
admin_home="$(ensure_ssh_dir "$ADMIN_USER")"
admin_auth="${admin_home}/.ssh/authorized_keys"
touch "$admin_auth"
admin_blob="$(awk '{print $2}' <<<"$admin_key")"
if ! grep -qF "$admin_blob" "$admin_auth"; then
  printf '%s\n' "$admin_key" >>"$admin_auth"
  log_change "ed25519 key added to ${admin_auth}"
fi
ensure_perms "$admin_auth" "${ADMIN_USER}:$(id -gn "$ADMIN_USER")" 600
# StrictModes: sshd ignores keys if the home is writable by group or others.
[[ "$(stat -c '%A' "$admin_home")" =~ ^d....-..-.$ ]] \
  || die "${admin_home} is group/other writable: sshd would reject the key (StrictModes)."

# --- AC-3: deploy account and key (restricted) -------------------------
allow_users="$ADMIN_USER"
if [[ -n $DEPLOY_SSH_PUBKEY_FILE ]]; then
  deploy_key="$(read_pubkey "$DEPLOY_SSH_PUBKEY_FILE")"
  install -m 755 -o root -g root "${SSH_INFRA}/autoops-deploy-entrypoint.sh" "$ENTRYPOINT"
  if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "AutoOps CI/CD deploy" "$DEPLOY_USER"
    passwd --lock "$DEPLOY_USER" >/dev/null
    log_change "created deploy account ${DEPLOY_USER} (no password, no sudo)"
  fi
  for forbidden in sudo docker; do
    if getent group "$forbidden" >/dev/null && in_group "$DEPLOY_USER" "$forbidden"; then
      gpasswd --delete "$DEPLOY_USER" "$forbidden" >/dev/null
      log_change "${DEPLOY_USER} removed from group ${forbidden}"
    fi
  done
  deploy_home="$(ensure_ssh_dir "$DEPLOY_USER")"
  deploy_group="$(id -gn "$DEPLOY_USER")"
  ensure_file "${deploy_home}/.ssh/authorized_keys" \
    "restrict,from=\"${DEPLOY_ALLOWED_FROM}\",command=\"${ENTRYPOINT}\" ${deploy_key}"
  ensure_perms "${deploy_home}/.ssh/authorized_keys" "${DEPLOY_USER}:${deploy_group}" 600
  allow_users="${ADMIN_USER} ${DEPLOY_USER}"
else
  log_info "No DEPLOY_SSH_PUBKEY_FILE: the deploy key is not configured."
fi

# --- AC-2 / AC-1: sshd drop-in with automatic rollback ---------------------
install -m 755 -o root -g root "${SSH_INFRA}/autoops-ssh-rollback.sh" "$ROLLBACK_BIN"
ensure_file "$BANNER" "Acceso restringido a personal autorizado. La actividad es registrada."

new_conf="$(sed "s/@ALLOW_USERS@/${allow_users}/" "${SSH_INFRA}/10-autoops.conf.tpl")"
if [[ -f $CONF && "$(cat "$CONF")" == "$new_conf" ]]; then
  log_info "${CONF} is already up to date."
else
  install -d -m 700 "$STATE_DIR"
  rm -f "$STATE_DIR"/10-autoops.conf.prev "$STATE_DIR"/10-autoops.conf.absent
  if [[ -f $CONF ]]; then cp -p "$CONF" "$STATE_DIR/10-autoops.conf.prev"; else : >"$STATE_DIR/10-autoops.conf.absent"; fi
  printf '%s\n' "$new_conf" >"$CONF"
  chmod 644 "$CONF"
  if ! /usr/sbin/sshd -t; then
    "$ROLLBACK_BIN" || true
    die "The new configuration does not pass 'sshd -t'; the previous one was restored."
  fi
  reload_sshd
  log_change "applied ${CONF} (sshd reloaded; open sessions are kept)"

  if has_systemd; then
    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
    systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${SSH_ROLLBACK_MINUTES}m" "$ROLLBACK_BIN"
    log_warn "ROLLBACK ARMED: this change will be reverted in ${SSH_ROLLBACK_MINUTES} min."
  else
    log_warn "No systemd: could not arm the automatic rollback; use ${ROLLBACK_BIN} if needed."
  fi
  log_warn "1) Open ANOTHER terminal and log in with your key.  2) If it works: sudo ADMIN_USER=${ADMIN_USER} $0 --confirm"
fi

log_info "20_ssh.sh finished."
