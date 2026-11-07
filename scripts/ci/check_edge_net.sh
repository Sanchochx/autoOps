#!/usr/bin/env bash
# Asserts the addressing of edge_net on the RESOLVED Compose model: Docker gives the dynamic addresses (gateway, frontend) out of
# ip_range only, so every fixed address (Traefik's) must be inside the subnet but OUTSIDE ip_range, or a container that starts
# first can take it and Traefik fails with "Address already in use". Also checks that the gateway trusts X-Forwarded-For from
# exactly Traefik's address. Runs in CI (job compose) and is exercised by test_edge_net_guard.sh.
#
#   scripts/ci/check_edge_net.sh                  # resolves `docker compose config --format json` (needs .env or the variables)
#   scripts/ci/check_edge_net.sh model.json      # or reads a resolved model from a file
#
# Exit 0 = consistent, 1 = a rule is broken (each one is printed), 2 = no usable model.
set -euo pipefail

if [[ $# -ge 1 ]]; then
  model="$(cat "$1")"
else
  model="$(docker compose config --format json)"
fi
[[ -n $model ]] || { echo "check_edge_net: empty model" >&2; exit 2; }

python3 - <<'PY' "$model"
import ipaddress
import json
import sys

model = json.loads(sys.argv[1])
failures = []


def ok(message: str) -> None:
    print(f"ok   {message}")


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)
    failures.append(message)


configs = (((model.get("networks") or {}).get("edge_net") or {}).get("ipam") or {}).get("config") or []
if len(configs) != 1 or "subnet" not in configs[0]:
    print("FAIL edge_net must declare exactly one ipam config with a subnet", file=sys.stderr)
    sys.exit(1)

subnet = ipaddress.ip_network(configs[0]["subnet"])
if "ip_range" not in configs[0]:
    fail("edge_net has no ip_range: dynamic addresses may take a fixed one")
    ip_range = None
else:
    ip_range = ipaddress.ip_network(configs[0]["ip_range"])
    if not ip_range.subnet_of(subnet):
        fail(f"ip_range {ip_range} is not inside the subnet {subnet}")
    elif ip_range.prefixlen <= subnet.prefixlen:
        fail(f"ip_range {ip_range} covers the whole subnet {subnet}: no room left for fixed addresses")
    else:
        ok(f"ip_range {ip_range} is a strict part of the subnet {subnet}")

reserved = {subnet.network_address, subnet.broadcast_address, subnet.network_address + 1}  # + the Docker gateway
fixed: dict[str, ipaddress.IPv4Address] = {}
for name, service in (model.get("services") or {}).items():
    edge = (service.get("networks") or {}).get("edge_net") if isinstance(service.get("networks"), dict) else None
    address = (edge or {}).get("ipv4_address")
    if not address:
        continue
    ip = ipaddress.ip_address(address)
    fixed[name] = ip
    if ip not in subnet:
        fail(f"{name}: fixed address {ip} is outside the subnet {subnet}")
    elif ip in reserved:
        fail(f"{name}: fixed address {ip} is the network, broadcast or gateway address of {subnet}")
    elif ip_range is not None and ip in ip_range:
        fail(f"{name}: fixed address {ip} is inside the dynamic ip_range {ip_range}")
    else:
        ok(f"{name}: fixed address {ip} is in {subnet} and outside the dynamic range")

if len(set(fixed.values())) != len(fixed):
    fail("two services share the same fixed address")
if "traefik" not in fixed:
    fail("traefik has no fixed address on edge_net")
else:
    allowed = ((model.get("services") or {}).get("api-gateway", {}).get("environment") or {}).get("FORWARDED_ALLOW_IPS")
    if allowed == str(fixed["traefik"]):
        ok(f"api-gateway trusts X-Forwarded-For only from Traefik ({allowed})")
    else:
        fail(f"FORWARDED_ALLOW_IPS is '{allowed}', expected Traefik's address {fixed['traefik']}")

sys.exit(1 if failures else 0)
PY
