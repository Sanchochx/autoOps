#!/usr/bin/env bash
# Verifies the controls of US-HOST-002 (read-only). Same variables as 20_ssh.sh:
#
#   sudo ADMIN_USER=<user> [DEPLOY_SSH_PUBKEY_FILE=<path.pub>] ./scripts/provision/checks/20_ssh.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_var ADMIN_USER
DEPLOY_USER="${DEPLOY_USER:-autoops-deploy}"
DEPLOY_SSH_PUBKEY_FILE="${DEPLOY_SSH_PUBKEY_FILE:-}"
ENTRYPOINT=/usr/local/sbin/autoops-deploy-entrypoint

# sshd_is <directive> <value>: compares against the effective configuration (sshd -T).
# (repeated directives, such as allowusers, are joined with spaces)
sshd_is() { [[ "$(/usr/sbin/sshd -T | awk -v k="$1" '$1 == k { $1 = ""; print substr($0, 2) }' | paste -sd' ')" == "$2" ]]; }
user_home()      { getent passwd "$1" | cut -d: -f6; }
perms_of()       { stat -c '%U %a' "$1"; }
sshd_valid()     { /usr/sbin/sshd -t; }
ssh_active()     { systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket; }
admin_dir()      { [[ "$(perms_of "$(user_home "$ADMIN_USER")/.ssh")" == "${ADMIN_USER} 700" ]]; }
admin_auth()     { [[ "$(perms_of "$(user_home "$ADMIN_USER")/.ssh/authorized_keys")" == "${ADMIN_USER} 600" ]]; }
admin_has_key()  { grep -Eq '^(ssh-ed25519|sk-ssh-ed25519@openssh\.com) ' "$(user_home "$ADMIN_USER")/.ssh/authorized_keys"; }
admin_only_ed()  { ! grep -Eqv '^(ssh-ed25519|sk-ssh-ed25519@openssh\.com) |^#|^$' "$(user_home "$ADMIN_USER")/.ssh/authorized_keys"; }
entrypoint_ok()  { [[ "$(stat -c '%U:%G %a' "$ENTRYPOINT")" == "root:root 755" ]]; }
deploy_no_priv() { ! in_group "$DEPLOY_USER" sudo && { ! getent group docker >/dev/null || ! in_group "$DEPLOY_USER" docker; }; }
deploy_locked()  { [[ "$(passwd_status "$DEPLOY_USER")" == L ]]; }
deploy_in_allow(){ sshd_is allowusers "${ADMIN_USER} ${DEPLOY_USER}"; }
deploy_restrict(){
  local f; f="$(user_home "$DEPLOY_USER")/.ssh/authorized_keys"
  [[ "$(grep -c . "$f")" == 1 ]] \
    && grep -Eq "^restrict,from=\"[0-9a-fA-F:./,]+\",command=\"${ENTRYPOINT}\" ssh-ed25519 " "$f" \
    && [[ "$(perms_of "$f")" == "${DEPLOY_USER} 600" ]]
}
no_pending_rb()  { ! command -v systemctl >/dev/null || ! systemctl is-active --quiet autoops-ssh-rollback.timer; }

check "sshd valida su configuración (sshd -t)" sshd_valid
check "el servicio ssh está activo" ssh_active
check "PasswordAuthentication no" sshd_is passwordauthentication no
check "KbdInteractiveAuthentication no" sshd_is kbdinteractiveauthentication no
check "PubkeyAuthentication yes" sshd_is pubkeyauthentication yes
check "AuthenticationMethods publickey" sshd_is authenticationmethods publickey
check "PermitRootLogin no" sshd_is permitrootlogin no
check "PermitEmptyPasswords no" sshd_is permitemptypasswords no
check "MaxAuthTries 3" sshd_is maxauthtries 3
check "LoginGraceTime 30" sshd_is logingracetime 30
check "X11Forwarding no" sshd_is x11forwarding no
check "AllowAgentForwarding no" sshd_is allowagentforwarding no
check "AllowTcpForwarding no" sshd_is allowtcpforwarding no
check "ClientAliveInterval 300 / CountMax 2" bash -c "$(declare -f sshd_is); sshd_is clientaliveinterval 300 && sshd_is clientalivecountmax 2"
check "banner configurado" sshd_is banner /etc/ssh/autoops-banner
# shellcheck disable=SC2088 # literal text of the description, not a path
check "~/.ssh de ${ADMIN_USER} es 700" admin_dir
check "authorized_keys de ${ADMIN_USER} es 600" admin_auth
check "${ADMIN_USER} tiene una llave ed25519" admin_has_key
check "authorized_keys de ${ADMIN_USER} solo contiene llaves ed25519" admin_only_ed
check "sin rollback de SSH pendiente (cambio confirmado)" no_pending_rb

if [[ -n $DEPLOY_SSH_PUBKEY_FILE ]]; then
  check "AllowUsers = ${ADMIN_USER} ${DEPLOY_USER}" deploy_in_allow
  check "entrypoint de despliegue root:root 755" entrypoint_ok
  check "${DEPLOY_USER} sin sudo ni docker" deploy_no_priv
  check "${DEPLOY_USER} sin contraseña (bloqueada)" deploy_locked
  check "llave de despliegue con restrict, from= y command=" deploy_restrict
else
  check "AllowUsers = ${ADMIN_USER}" sshd_is allowusers "$ADMIN_USER"
  log_info "Sin DEPLOY_SSH_PUBKEY_FILE: se omiten los controles de la llave de despliegue."
fi

check_finish
