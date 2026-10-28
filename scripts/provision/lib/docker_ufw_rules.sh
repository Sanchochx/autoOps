#!/usr/bin/env bash
# Expected DOCKER-USER block, shared by 45_docker_ufw.sh and its check. Loaded with `source`.
# Requires lib/common.sh and REPO_ROOT.
source "$(dirname "${BASH_SOURCE[0]}")/ufw_rules.sh"

DOCKER_USER_TPL="${REPO_ROOT}/infra/firewall/docker-user.rules.tpl"
# shellcheck disable=SC2034 # read by the scripts that source this library
AFTER_RULES=/etc/ufw/after.rules
BLOCK_BEGIN='# BEGIN AUTOOPS DOCKER-USER'
BLOCK_END='# END AUTOOPS DOCKER-USER'

# resolve_public_ports: host ports that may receive external traffic to containers.
# Always the web ports UFW opens (resolve_web_ports: the proxy's PROXY_HTTP_PORT / PROXY_HTTPS_PORT unless
# UFW_WEB_PORTS overrides them) so UFW and DOCKER-USER agree; DOCKER_PUBLIC_PORTS may add more.
# Warns if the list still contains the legacy PORT / FRONTEND_PORT of APP_ENV_FILE (US-PROXY-003).
resolve_public_ports() {
  local env_file="${APP_ENV_FILE:-${APP_DIR:-/opt/autoops}/.env}" ports port legacy key
  ports="${DOCKER_PUBLIC_PORTS:-} $(resolve_web_ports)"
  for port in $ports; do
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "Puerto público inválido: '${port}'."
  done
  # shellcheck disable=SC2086
  ports="$(printf '%s\n' $ports | sort -nu | paste -sd' ')"
  for key in PORT FRONTEND_PORT; do
    legacy="$(env_value "$env_file" "$key")"
    [[ -n $legacy && " ${ports} " == *" ${legacy} "* ]] \
      && log_warn "El puerto ${legacy} (${key}) sigue como público; Traefik es la única entrada. Quítalo de DOCKER_PUBLIC_PORTS/UFW_WEB_PORTS."
  done
  printf '%s\n' "$ports"
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

# external_host_ports <docker ps "Ports" field>: host ports published on non-loopback addresses, one per line.
# Field format: "0.0.0.0:80->80/tcp, [::]:80->80/tcp, 127.0.0.1:5432->5432/tcp, 8000/tcp".
# Loopback bindings (e.g. docker-compose.dev-db.yml) and unpublished ports are not reachable from outside.
external_host_ports() {
  local entry
  while IFS= read -r entry; do
    [[ $entry == *'->'* ]] || continue
    case $entry in 127.* | '[::1]'*) continue ;; esac
    sed -E 's/^.*:([0-9]+)(-[0-9]+)?->.*$/\1/' <<<"$entry"
  done < <(tr ',' '\n' <<<"$1" | sed -E 's/^[[:space:]]+//')
}
