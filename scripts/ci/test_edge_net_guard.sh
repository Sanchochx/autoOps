#!/usr/bin/env bash
# Exercises scripts/ci/check_edge_net.sh on a small resolved model: the consistent one passes and each rule turns the guard red
# when its own condition is broken (one mutation per check). No Docker needed.
#
#   scripts/ci/test_edge_net_guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${ROOT}/scripts/ci/check_edge_net.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

cat >"${WORK}/base.json" <<'JSON'
{
  "networks": {"edge_net": {"ipam": {"config": [{"subnet": "172.30.250.0/24", "ip_range": "172.30.250.128/25"}]}}},
  "services": {
    "traefik": {"networks": {"edge_net": {"ipv4_address": "172.30.250.2"}}},
    "api-gateway": {"networks": {"edge_net": null, "backend_net": null}, "environment": {"FORWARDED_ALLOW_IPS": "172.30.250.2"}},
    "frontend": {"networks": {"edge_net": null}}
  }
}
JSON

# mutate <python statements acting on m>: writes the mutated model to ${WORK}/m.json and runs the guard (OUT / RC).
mutate() {
  python3 - "${WORK}/base.json" "${WORK}/m.json" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(m, open(sys.argv[2], "w"))
PY
  OUT="$("$GUARD" "${WORK}/m.json" 2>&1)"; RC=$?
}
check() { # description, command...
  local d=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   - $d"; else FAIL=$((FAIL + 1)); echo "FAIL - $d"; printf '       %s\n' "${OUT//$'\n'/$'\n       '}"; fi
}
only_fails() { [[ $RC == 1 && $(grep -c '^FAIL' <<<"$OUT") == 1 ]] && grep -q "^FAIL.*$1" <<<"$OUT"; }

mutate ''
check "consistent model passes" test "$RC" = 0
mutate 'm["services"]["traefik"]["networks"]["edge_net"]["ipv4_address"] = "172.30.250.130"; m["services"]["api-gateway"]["environment"]["FORWARDED_ALLOW_IPS"] = "172.30.250.130"'
check "Traefik's fixed address inside ip_range (the original bug) is rejected" only_fails "inside the dynamic ip_range"
mutate 'del m["networks"]["edge_net"]["ipam"]["config"][0]["ip_range"]'
check "no ip_range is rejected" only_fails "no ip_range"
mutate 'm["networks"]["edge_net"]["ipam"]["config"][0]["ip_range"] = "172.30.250.0/24"'
check "ip_range covering the whole subnet is rejected" bash -c "[[ $RC == 1 ]] && grep -q '^FAIL.*whole subnet' <<<'$OUT'"
mutate 'm["networks"]["edge_net"]["ipam"]["config"][0]["ip_range"] = "10.0.0.0/25"'
check "ip_range outside the subnet is rejected" only_fails "not inside the subnet"
mutate 'm["services"]["traefik"]["networks"]["edge_net"]["ipv4_address"] = "10.9.9.9"; m["services"]["api-gateway"]["environment"]["FORWARDED_ALLOW_IPS"] = "10.9.9.9"'
check "fixed address outside the subnet is rejected" only_fails "outside the subnet"
mutate 'm["services"]["traefik"]["networks"]["edge_net"]["ipv4_address"] = "172.30.250.1"; m["services"]["api-gateway"]["environment"]["FORWARDED_ALLOW_IPS"] = "172.30.250.1"'
check "the Docker gateway address as fixed address is rejected" only_fails "gateway address"
mutate 'm["services"]["traefik"]["networks"]["edge_net"]["ipv4_address"] = "172.30.250.255"; m["services"]["api-gateway"]["environment"]["FORWARDED_ALLOW_IPS"] = "172.30.250.255"'
check "the broadcast address as fixed address is rejected" only_fails "broadcast"
mutate 'm["services"]["api-gateway"]["environment"]["FORWARDED_ALLOW_IPS"] = "*"'
check "FORWARDED_ALLOW_IPS other than Traefik's address is rejected" only_fails "FORWARDED_ALLOW_IPS"
mutate 'm["services"]["traefik"]["networks"] = {"edge_net": None}'
check "Traefik without a fixed address is rejected" only_fails "no fixed address"
mutate 'm["services"]["frontend"]["networks"]["edge_net"] = {"ipv4_address": "172.30.250.2"}'
check "two services with the same fixed address are rejected" only_fails "same fixed address"
mutate 'm["networks"]["edge_net"]["ipam"]["config"] = []'
check "edge_net without an ipam config is rejected" bash -c "[[ $RC == 1 ]]"

echo "passed=${PASS} failed=${FAIL}"
[[ $FAIL -eq 0 ]]
