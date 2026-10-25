#!/usr/bin/env bash
# US-PROV-001 (AC-3): runs every checks/*.sh (read-only) and prints an OK/FAIL table per control group.
#
#   sudo ADMIN_USER=<user> FAIL2BAN_IGNOREIP="<IP/CIDR ...>" ./scripts/provision/verify.sh [--env-file <provision.env>] [-q]
#
# Takes the same variables as bootstrap.sh (see provision.env.example), including the optional ones the
# checks honour (ADMIN_CIDR, UFW_WEB_PORTS, EXPECTED_TCP_PORTS, STACK_REQUIRED, ...).
# -q / --quiet: print only the failing controls and the summary table.
# Exit code: 0 if every check passed, 1 if any failed or could not run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIET=0
ENV_FILE="${PROVISION_ENV_FILE:-}"
while (($#)); do
  case $1 in
    -q | --quiet) QUIET=1 ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requiere una ruta."
      ENV_FILE=$2
      shift
      ;;
    -h | --help) sed -n '2,/^set -/{/^set -/!s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Argumento desconocido '$1' (admitidos: --env-file, -q, --help)." ;;
  esac
  shift
done

require_root
[[ -z $ENV_FILE ]] || load_env_file "$ENV_FILE"
export APP_DIR="${APP_DIR:-/opt/autoops}"

shopt -s nullglob
CHECKS=("${HERE}"/checks/*.sh)
((${#CHECKS[@]} > 0)) || die "No hay scripts en ${HERE}/checks/."

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
names=() results=() oks=() fails=()
failed=0

for script in "${CHECKS[@]}"; do
  name="$(basename "$script" .sh)"
  # A check that dies before reporting (missing variable, tool, ...) counts as failed.
  rc=0
  bash "$script" >"$OUT" 2>&1 || rc=$?
  ok="$(grep -c '^\[ OK \]' "$OUT" || true)"
  bad="$(grep -c '^\[FAIL\]' "$OUT" || true)"
  if ((rc != 0 || bad > 0)); then status=FAIL; failed=$((failed + 1)); else status=OK; fi

  names+=("$name"); results+=("$status"); oks+=("$ok"); fails+=("$bad")
  printf '\n=== %s ===\n' "$name"
  if ((QUIET)) && [[ $status == OK ]]; then
    printf '[ OK ]   %s controles\n' "$ok"
  elif ((QUIET)); then
    grep -v '^\[ OK \]' "$OUT" || true
  else
    cat "$OUT"
  fi
  # Script-level failure with no failing control (e.g. require_var): rc != 0 and bad == 0.
  if ((rc != 0 && bad == 0)); then printf '[FAIL]   %s terminó con código %d antes de completar sus controles\n' "$name" "$rc"; fi
done

printf '\n%-22s %-6s %s\n' "CONTROL" "ESTADO" "OK/FAIL"
printf '%-22s %-6s %s\n' "----------------------" "------" "-------"
for i in "${!names[@]}"; do
  printf '%-22s %-6s %s/%s\n' "${names[$i]}" "${results[$i]}" "${oks[$i]}" "${fails[$i]}"
done

if ((failed > 0)); then
  printf '\nFAIL: %d de %d grupos de controles fallaron.\n' "$failed" "${#names[@]}" >&2
  exit 1
fi
printf '\nOK: los %d grupos de controles pasaron.\n' "${#names[@]}"
