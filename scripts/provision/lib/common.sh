#!/usr/bin/env bash
# Utilities shared by the provisioning scripts and their checks.
# Loaded with `source`; not executed directly.

log_info()   { printf '[INFO]   %s\n' "$*"; }
log_change() { printf '[CAMBIO] %s\n' "$*"; }
log_warn()   { printf '[AVISO]  %s\n' "$*" >&2; }
die()        { printf '[ERROR]  %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Ejecuta este script con sudo o como root."
}

require_var() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "Falta la variable obligatoria ${name}."
  done
}

# in_group <user> <group>: succeeds if the user belongs to the group.
# (no pipes: with `pipefail`, `grep -q` can cause false negatives)
in_group() {
  local group
  for group in $(id -nG "$1" 2>/dev/null); do
    [[ $group == "$2" ]] && return 0
  done
  return 1
}

# passwd_status <user>: P (usable password), L (locked) or NP (no password).
passwd_status() {
  passwd -S "$1" | awk '{print $2}'
}

# ensure_perms <path> <owner:group> <mode>: fixes only if there is a difference.
ensure_perms() {
  local path=$1 owner=$2 mode=$3
  if [[ "$(stat -c '%U:%G %a' "$path")" != "${owner} ${mode}" ]]; then
    chown "$owner" "$path"
    chmod "$mode" "$path"
    log_change "${path} -> ${owner} ${mode}"
  fi
}

# ensure_file <path> <content>: writes the file only if it changes and sets
# FILE_CHANGED=1 (or 0) so the caller can decide whether to reload something.
FILE_CHANGED=0
ensure_file() {
  local path=$1 content=$2
  FILE_CHANGED=0
  if [[ ! -f $path ]] || [[ "$(cat "$path")" != "$content" ]]; then
    printf '%s\n' "$content" >"$path"
    FILE_CHANGED=1
    log_change "escrito ${path}"
  fi
}

# load_env_file <file>: exports KEY=VALUE lines (quoted values allowed) without sourcing the file, so it
# cannot run code. Variables already set in the environment win. Aborts on malformed lines, on
# loader-sensitive names (PATH, LD_*, ...) and on files writable by group/others.
load_env_file() {
  local file=$1 line key value n=0
  [[ -r $file ]] || die "No se puede leer el archivo de variables '${file}'."
  [[ "$(stat -c '%A' "$file")" =~ ^-....-..-.$ ]] \
    || die "${file} admite escritura de grupo/otros; corrige con chmod go-w."
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "${file}:${n}: línea inválida (se espera NOMBRE=valor)."
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ $key =~ ^(PATH|IFS|ENV|BASH_ENV|SHELLOPTS|LD_.*|HOME)$ ]] && die "${file}:${n}: variable no permitida '${key}'."
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value="${BASH_REMATCH[1]}"; fi
    [[ -n ${!key:-} ]] || export "${key}=${value}"
  done <"$file"
}

# env_file_value <file> <NAME>: the value of NAME, from the process environment first and then from
# the file (the precedence docker compose uses). The file is parsed, never sourced.
env_file_value() {
  local file=$1 name=$2 line
  if [[ -n ${!name:-} ]]; then printf '%s' "${!name}"; return; fi
  line="$(grep -E "^${name}=" "$file" 2>/dev/null | tail -n1)" || true
  line="${line#*=}"; line="${line%\"}"; printf '%s' "${line#\"}"
}

# --- Checks: each `check` prints OK/FAIL and accumulates failures ---------------------
CHECK_FAILS=0

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '[ OK ]   %s\n' "$description"
  else
    printf '[FAIL]   %s\n' "$description"
    CHECK_FAILS=$((CHECK_FAILS + 1))
  fi
}

check_finish() {
  if ((CHECK_FAILS > 0)); then
    printf '\n%d control(es) fallaron.\n' "$CHECK_FAILS" >&2
    exit 1
  fi
  printf '\nTodos los controles pasaron.\n'
}

# resolve_ssh_port: prints the SSH port (SSH_PORT or, if unset, sshd -T's effective one).
resolve_ssh_port() {
  local port="${SSH_PORT:-}"
  if [[ -z $port ]]; then
    [[ -x /usr/sbin/sshd ]] || die "openssh-server no está instalado y SSH_PORT no se definió."
    port="$(/usr/sbin/sshd -T | awk '$1 == "port" { print $2; exit }')"
  fi
  [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "SSH_PORT inválido: '${port}'."
  printf '%s' "$port"
}
