# Docker ↔ UFW coherence

Managed by `scripts/provision/45_docker_ufw.sh` (verification: `scripts/provision/checks/45_docker_ufw.sh`).

| File | Host destination |
|---|---|
| `docker-user.rules.tpl` | Managed block inside `/etc/ufw/after.rules` (`DOCKER-USER` chain) |

## Why UFW is not enough (AC-1)

Docker publishes ports with DNAT in `PREROUTING` and accepts the resulting traffic in its `DOCKER` chain (`filter` table, `FORWARD`). That path does not go through `ufw-user-input` (which only filters `INPUT`), so `ufw default deny incoming` has no effect on a `ports: "8000:8000"` mapping. The `deny routed` policy does not cover it either, because Docker inserts its rules before UFW's.

Reproduction (with the stack up and UFW active, **without** the block applied), from another machine:

```bash
nmap -Pn -p 22,3000,5001,8000 <vm-ip>   # 3000 and 8000 show up as "open" without a UFW rule
curl -sS -o /dev/null -w '%{http_code}\n' http://<vm-ip>:8000/health
```

_Result captured on the VM: pending (before/after)._

## Design (AC-2)

Docker evaluates `DOCKER-USER` first in `FORWARD` and never flushes it. The block:

1. `ESTABLISHED,RELATED` → `RETURN`: replies to outbound connections from containers.
2. For each external interface and public port → `RETURN` if the connection was DNAT-ed **with that original destination port** (`-m conntrack --ctstate DNAT --ctorigdstport <p> --ctdir ORIGINAL`). In `FORWARD` the packet already carries the container's *internal* port, which is why `--dport` does not work.
3. Everything else entering through the external interface → `DROP`.
4. Final `RETURN`: traffic between containers (`br-*`, `docker0`) and from the host is left untouched, so `backend_net` and `mcp_net` keep working.

`iptables` remains managed by Docker (`"iptables": false` is not used).

## Variables (all optional)

| Variable | Description |
|---|---|
| `DOCKER_EXT_IFACES` | External interfaces, space-separated. Defaults to those on the default route. On VirtualBox with NAT + host-only, list both if both must be filtered |
| `DOCKER_PUBLIC_PORTS` | Extra host ports reachable from outside, on top of the proxy ports. Defaults to none; a warning is logged if it lists the gateway's `PORT` |
| `APP_ENV_FILE` | Deployment `.env` (`/opt/autoops/.env`) |
| `UFW_WEB_PORTS` | Always-public web ports. Defaults to `PROXY_HTTP_PORT` and `PROXY_HTTPS_PORT` from `APP_ENV_FILE` (what Traefik publishes), the same resolution as `40_ufw.sh` |
| `DOCKER_UFW_DRY_RUN=1` | Prints the block without applying it |

## Public ports (US-PROXY-003)

Traefik is the only service that publishes host ports, so the only public ports are `PROXY_HTTP_PORT` (redirects to HTTPS) and `PROXY_HTTPS_PORT`. UFW (`40_ufw.sh`) and `DOCKER-USER` (`45_docker_ufw.sh`) derive them from the same `.env` variables as `docker-compose.yml`, so they cannot drift apart. The gateway's `PORT` is internal to `edge_net`; the old frontend port no longer exists.

## Known limits

- IPv4 only: Docker does not enable `ip6tables` (no `ipv6`/`ip6tables` in `daemon.json`), so no ports are published over IPv6.
- fail2ban bans (`banaction=ufw`) act on `INPUT`: they do not block ports published by Docker.
- The block applies to TCP; if you publish UDP, add its rule explicitly.

## External scan (AC-4)

```bash
nmap -Pn -sS -p- <vm-ip>      # must show only SSH and the defined public ports
```

_Result: pending, to be attached after applying the block._
