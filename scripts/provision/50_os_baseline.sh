#!/usr/bin/env bash
# US-SYS-001: OS baseline, automatic patches, time and sysctl. Idempotent.
#
#   sudo ./scripts/provision/50_os_baseline.sh
#
# Variables (all optional):
#   TIMEZONE=UTC             server time zone
#   AUTO_REBOOT_TIME         HH:MM; if set, unattended-upgrades reboots at that time when
#                            a patch requires it. Default: no automatic reboot.
#   EXTRA_PACKAGES="git htop tree"  admin utilities (in addition to the mandatory ones)
#   APT_UPGRADE=1            run `apt-get upgrade` (0 = only refresh the index)
#   DISABLE_SERVICES="avahi-daemon cups cups-browsed rpcbind bluetooth ModemManager apport"
#                            unneeded services to disable if present (apport: its crash handler sets fs.suid_dumpable=2, the baseline wants 0)
# See infra/sysctl/ for kernel parameters.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYSCTL_SRC="${REPO_ROOT}/infra/sysctl/99-autoops.conf"
SYSCTL_DST=/etc/sysctl.d/99-autoops.conf
UU_AUTO=/etc/apt/apt.conf.d/20auto-upgrades
UU_CONF=/etc/apt/apt.conf.d/52autoops-unattended-upgrades

require_root
TIMEZONE="${TIMEZONE:-UTC}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-}"
EXTRA_PACKAGES="${EXTRA_PACKAGES-git htop tree}"
APT_UPGRADE="${APT_UPGRADE:-1}"
DISABLE_SERVICES="${DISABLE_SERVICES-avahi-daemon cups cups-browsed rpcbind bluetooth ModemManager apport}"
# ca-certificates/curl/gnupg: prerequisites of Docker's apt repository (US-SYS-002).
REQUIRED_PACKAGES="ca-certificates curl gnupg jq chrony unattended-upgrades"

[[ $AUTO_REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ || -z $AUTO_REBOOT_TIME ]] || die "AUTO_REBOOT_TIME debe ser HH:MM."
[[ $APT_UPGRADE =~ ^[01]$ ]] || die "APT_UPGRADE debe ser 0 o 1."
for var in EXTRA_PACKAGES DISABLE_SERVICES; do
  [[ ${!var} =~ ^[A-Za-z0-9.+:_[:space:]-]*$ ]] || die "${var} contiene caracteres no válidos."
done
timedatectl list-timezones | grep -qxF "$TIMEZONE" || die "TIMEZONE inválida: '${TIMEZONE}'."

has_systemd() { [[ -d /run/systemd/system ]]; }
export DEBIAN_FRONTEND=noninteractive

# --- AC-1: minimal packages and unneeded services ---------------------------------
missing=()
for pkg in $REQUIRED_PACKAGES $EXTRA_PACKAGES; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]} > 0 || APT_UPGRADE == 1)); then
  apt-get update -qq
fi
if ((APT_UPGRADE == 1)); then
  apt-get upgrade -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  log_info "sistema actualizado (apt-get upgrade)"
fi
if ((${#missing[@]} > 0)); then
  apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}"
  log_change "instalados: ${missing[*]}"
fi

if has_systemd; then
  for svc in $DISABLE_SERVICES; do
    for unit in "${svc}.service" "${svc}.socket"; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
        if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit"; then
          systemctl disable --now "$unit" >/dev/null 2>&1 || true
          log_change "deshabilitado ${unit}"
        fi
      fi
    done
  done
fi
log_info "Puertos en escucha (revisa que solo quede SSH y servicios internos de systemd):"
ss -tulpn || true

# --- AC-2: automatic security patches ---------------------------------------------
ensure_file "$UU_AUTO" 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'

if [[ -n $AUTO_REBOOT_TIME ]]; then
  reboot_cfg="Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${AUTO_REBOOT_TIME}\";"
else
  reboot_cfg='Unattended-Upgrade::Automatic-Reboot "false";'
fi
# `#clear` discards the origins from 50unattended-upgrades: only the security channel (+ ESM).
# SyslogEnable sends logs to journald as well.
ensure_file "$UU_CONF" "#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Allowed-Origins {
  \"\${distro_id}:\${distro_codename}-security\";
  \"\${distro_id}ESMApps:\${distro_codename}-apps-security\";
  \"\${distro_id}ESM:\${distro_codename}-infra-security\";
};
Unattended-Upgrade::SyslogEnable \"true\";
${reboot_cfg}"
if has_systemd; then
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
fi

# --- AC-3: time (chrony + time zone) -------------------------------------------------------
if [[ "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
  log_change "zona horaria -> ${TIMEZONE}"
fi
if has_systemd; then
  systemctl enable --now chrony >/dev/null 2>&1
  if ! chronyc tracking 2>/dev/null | grep -q 'Leap status *: Normal'; then
    log_info "Esperando sincronización de chrony (hasta ~30 s)..."
    timeout 40 chronyc waitsync 3 >/dev/null 2>&1 || log_warn "chrony aún no está sincronizado (¿hay salida a Internet/NTP?)."
  fi
fi

# --- AC-4: sysctl --------------------------------------------------------------------------------
ensure_file "$SYSCTL_DST" "$(cat "$SYSCTL_SRC")"
chmod 644 "$SYSCTL_DST"
if ((FILE_CHANGED)); then
  sysctl --system >/dev/null
  log_change "parámetros de kernel aplicados (sysctl --system)"
fi

log_info "50_os_baseline.sh finalizado."
