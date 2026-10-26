#!/usr/bin/env bash
# Local CA and leaf certificate helpers (US-PROXY-002 AC-1). Loaded with `source` after lib/common.sh.
#
# Layout under <dir> (TLS_DIR):
#   ca/ca.key       root CA private key   0400, never mounted into any container
#   ca/ca.crt       root CA certificate   0644, the file to import into the browser/OS
#   server/cert.pem leaf certificate      0444 } the only files Traefik sees (mounted read-only),
#   server/key.pem  leaf private key      0400 } owned by the proxy UID:GID
#
# Every function takes the directory as an argument so the logic can be exercised unprivileged
# against a temporary directory (see 65_tls.sh for the root/ownership wrapper).

TLS_CA_DAYS=3650
TLS_LEAF_DAYS=365            # browsers reject server certificates valid for more than ~398 days
TLS_RENEW_BEFORE_DAYS=30

# tls_desired_sans <name>...: normalised, sorted, unique "DNS:x" / "IP:y" lines. IPv6 is rejected:
# OpenSSL prints it expanded, which would make the SAN comparison (and so idempotency) unreliable.
tls_desired_sans() {
  local name
  for name in "$@"; do
    if [[ $name =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "IP:${name}"
    elif [[ $name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
      echo "DNS:${name,,}"
    else
      die "Nombre de certificado inválido: '${name}' (se admiten nombres DNS e IPv4; IPv6 no)."
    fi
  done | sort -u
}

# tls_cert_sans <cert>: the SANs actually present in a certificate, in the same normalised form.
tls_cert_sans() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | sed -n '2p' | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/^IP Address:/IP:/' \
    | awk -F: 'NF { print $1 ":" tolower($2) }' | sort -u
}

# tls_pubkey_matches <cert> <key>: the private key belongs to the certificate.
tls_pubkey_matches() {
  [[ "$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" == "$(openssl pkey -in "$2" -pubout 2>/dev/null)" ]]
}

# tls_ensure_ca <dir>: creates the root CA if absent. A half-present CA is an error, never silently
# replaced: regenerating it would invalidate every browser that imported the old one.
tls_ensure_ca() {
  local ca="$1/ca"
  if [[ -f $ca/ca.key && -f $ca/ca.crt ]]; then
    tls_pubkey_matches "$ca/ca.crt" "$ca/ca.key" || die "${ca}: ca.key y ca.crt no son un par. Revisa o elimina el directorio ca/ a mano."
    openssl x509 -in "$ca/ca.crt" -noout -checkend $((90 * 86400)) >/dev/null \
      || log_warn "La CA local de ${ca} caduca en menos de 90 días; regenerarla obliga a reimportarla en los navegadores."
    return 0
  fi
  [[ ! -e $ca/ca.key && ! -e $ca/ca.crt ]] || die "${ca}: CA incompleta (falta ca.key o ca.crt). Revisa o elimina el directorio ca/ a mano."

  install -d -m 755 "$ca"
  (
    umask 077
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ca/ca.key" 2>/dev/null
  )
  chmod 0400 "$ca/ca.key"
  openssl req -x509 -new -key "$ca/ca.key" -sha256 -days "$TLS_CA_DAYS" \
    -subj "/O=AutoOps/CN=AutoOps Local CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$ca/ca.crt"
  chmod 0644 "$ca/ca.crt"
  log_change "creada la CA local ${ca}/ca.crt (${TLS_CA_DAYS} días)"
}

# tls_leaf_valid <dir> <name>...: succeeds if the leaf exists, is signed by the CA, matches its key,
# has at least TLS_RENEW_BEFORE_DAYS left and carries exactly the wanted SANs.
tls_leaf_valid() {
  local dir=$1 crt="$1/server/cert.pem" key="$1/server/key.pem"
  shift
  [[ -f $crt && -f $key ]] || return 1
  openssl verify -CAfile "$dir/ca/ca.crt" "$crt" >/dev/null 2>&1 || return 1
  tls_pubkey_matches "$crt" "$key" || return 1
  openssl x509 -in "$crt" -noout -checkend $((TLS_RENEW_BEFORE_DAYS * 86400)) >/dev/null 2>&1 || return 1
  [[ "$(tls_cert_sans "$crt")" == "$(tls_desired_sans "$@")" ]]
}

# tls_issue_leaf <dir> <name>...: signs a new leaf for the names (the first one is the main host).
# Replaces server/cert.pem and server/key.pem; ownership is applied afterwards by tls_enforce_perms.
tls_issue_leaf() {
  local dir=$1 srv="$1/server" tmp sans
  shift
  sans="$(tls_desired_sans "$@" | paste -sd, -)"
  install -d -m 750 "$srv"
  tmp="$(mktemp -d "${dir}/.issue.XXXXXX")"
  (
    umask 077
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/key.pem" 2>/dev/null
    openssl req -new -key "$tmp/key.pem" -subj "/O=AutoOps/CN=${1:0:60}" -out "$tmp/leaf.csr"
    cat >"$tmp/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
subjectAltName=${sans}
EOF
    openssl x509 -req -in "$tmp/leaf.csr" -CA "$dir/ca/ca.crt" -CAkey "$dir/ca/ca.key" \
      -CAcreateserial -days "$TLS_LEAF_DAYS" -sha256 -extfile "$tmp/ext.cnf" -out "$tmp/cert.pem" 2>/dev/null
  )
  # New names first, then moved into place, so a failure above never leaves half a leaf behind.
  install -m 0400 "$tmp/key.pem" "$srv/key.pem.new"
  install -m 0444 "$tmp/cert.pem" "$srv/cert.pem.new"
  mv -f "$srv/key.pem.new" "$srv/key.pem"
  mv -f "$srv/cert.pem.new" "$srv/cert.pem"
  rm -rf "$tmp"
  log_change "emitido el certificado de ${1} (SAN: ${sans}; ${TLS_LEAF_DAYS} días)"
}

# tls_ensure_perms <path> <uid:gid> <mode>: like ensure_perms but compares NUMERIC ids, so the result
# does not depend on whether the proxy UID happens to have a name in /etc/passwd.
tls_ensure_perms() {
  local path=$1 ids=$2 mode=$3
  if [[ "$(stat -c '%u:%g %a' "$path")" != "${ids} ${mode}" ]]; then
    chown "$ids" "$path"
    chmod "$mode" "$path"
    log_change "${path} -> ${ids} ${mode}"
  fi
}

# tls_enforce_perms <dir> <uid:gid>: the proxy must read the leaf and nobody else may.
# The CA lives outside server/ and stays root-only.
tls_enforce_perms() {
  local dir=$1 ids=$2
  tls_ensure_perms "${dir}/ca" 0:0 755
  tls_ensure_perms "${dir}/ca/ca.key" 0:0 400
  tls_ensure_perms "${dir}/ca/ca.crt" 0:0 644
  tls_ensure_perms "${dir}/server" "$ids" 750
  tls_ensure_perms "${dir}/server/key.pem" "$ids" 400
  tls_ensure_perms "${dir}/server/cert.pem" "$ids" 444
}
