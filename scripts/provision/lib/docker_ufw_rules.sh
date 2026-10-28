#!/usr/bin/env bash
# Expected DOCKER-USER block, shared by 45_docker_ufw.sh and its check. Loaded with `source`.
# Requires lib/common.sh and REPO_ROOT.

DOCKER_USER_TPL="${REPO_ROOT}/infra/firewall/docker-user.rules.tpl"
AFTER_RULES=/etc/ufw/after.rules
BLOCK_BEGIN='# BEGIN AUTOOPS DOCKER-USER'
BLOCK_END='# END AUTOOPS DOCKER-USER'

# resolve_public_ports: host ports that may receive external traffic to containers.
# DOCKER_PUBLIC_PORTS takes precedence; if empty, PORT and FRONTEND_PORT from APP_ENV_FILE. Always
# UFW_WEB_PORTS (80/443 from Phase 5) are added so UFW and DOCKER-USER agree.
resolve_public_ports() {
  local ports="${DOCKER_PUBLIC_PORTS:-}" env_file="${APP_ENV_FILE:-/opt/autoops/.env}" port
  if [[ -z $ports && -r $env_file ]]; then
    ports="$(env_value "$env_file" PORT) $(env_value "$env_file" FRONTEND_PORT)"
  fi
  ports="${ports} ${UFW_WEB_PORTS:-}"
  for port in $ports; do
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "Puerto público inválido: '${port}'."
  done
  # shellcheck disable=SC2086
  printf '%s\n' $ports | sort -nu | paste -sd' '
}

# resolve_ext_ifaces: interfaces through which external traffic arrives (DOCKER_EXT_IFACES or the default route).
resolve_ext_ifaces() {
  local ifaces="${DOCKER_EXT_IFACES:-}" iface
  [[ -n $ifaces ]] || ifaces="$(ip -o route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' | sort -u | paste -sd' ')"
  [[ -n $ifaces ]] || die "Sin ruta por defecto: define DOCKER_EXT_IFACES (ej. \"enp0s3\")."
  for iface in $ifaces; do
    [[ $iface =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Interfaz inválida: '${iface}'."
    [[ -d /sys/class/net/$iface ]] || die "La interfaz '${iface}' no existe en este host."
    case $iface in lo | docker0 | br-* | veth*) die "'${iface}' no es una interfaz externa." ;; esac
  done
  printf '%s' "$ifaces"
}

# render_docker_user_block <ifaces> <ports>: the complete block, ready for after.rules.
render_docker_user_block() {
  local ifaces=$1 ports=$2 iface port allow='' drop='' line
  for iface in $ifaces; do
    for port in $ports; do
      allow+="-A DOCKER-USER -i ${iface} -p tcp -m conntrack --ctstate DNAT --ctorigdstport ${port} --ctdir ORIGINAL -j RETURN"$'\n'
    done
    drop+="-A DOCKER-USER -i ${iface} -j DROP"$'\n'
  done
  while IFS= read -r line; do
    case $line in
      @@ALLOW_RULES@@) [[ -z $allow ]] || printf '%s' "$allow" ;;
      @@DROP_RULES@@) printf '%s' "$drop" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$DOCKER_USER_TPL"
}

# current_block <file>: the managed block as installed ("" if absent).
current_block() {
  sed -n "/^${BLOCK_BEGIN}/,/^${BLOCK_END}\$/p" "$1" 2>/dev/null
}

# insert_block <file> <block>: replaces the managed block (or adds it before the final COMMIT).
insert_block() {
  local file=$1 block=$2 tmp
  tmp="$(mktemp)"
  BLOCK="$block" awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, b) == 1 { skip = 1 }
    !skip { lines[++n] = $0 }
    skip && index($0, e) == 1 { skip = 0 }
    END {
      for (last = n; last > 0 && lines[last] != "COMMIT"; last--) ;
      if (!last) { print "after.rules sin COMMIT final" > "/dev/stderr"; exit 1 }
      for (i = 1; i < last; i++) print lines[i]
      print ENVIRON["BLOCK"]
      for (i = last; i <= n; i++) print lines[i]
    }' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" >"$file"
  rm -f "$tmp"
}
