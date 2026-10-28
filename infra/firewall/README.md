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

## External validation (US-PROXY-003 AC-5)

Run both from ANOTHER machine (or the VirtualBox host), never from the VM:

```bash
# 1. Perimeter as designed: proxy ports answer (http redirects, https serves with the local CA),
#    and the gateway, old frontend, PostgreSQL, MCP and Docker API ports do not.
DOMAIN=<domain> ./scripts/ops/check_perimeter.sh <vm-ip> --ca <ca.crt>

# 2. Full TCP scan: only SSH (per ADMIN_CIDR) and the proxy ports may show up.
nmap -Pn -sS -p- <vm-ip>
```

`ca.crt` is exported as described in [`../traefik/README.md`](../traefik/README.md). `CLOSED_PORTS` overrides the list of
ports that must stay closed.

Evidence (US-PROXY-003 AC-5), `check_perimeter.sh` against the VM at `10.0.2.15`:

```
[ OK ]   puerto 80 abierto (proxy)
[ OK ]   puerto 443 abierto (proxy)
[ OK ]   http redirige a https (301 https://autoops.local/)
[ OK ]   https://autoops.local:443/ responde 200 (cadena verificada con la CA local)
[ OK ]   puerto 8000 cerrado o filtrado
[ OK ]   puerto 3000 cerrado o filtrado
[ OK ]   puerto 5432 cerrado o filtrado
[ OK ]   puerto 5001 cerrado o filtrado
[ OK ]   puerto 2375 cerrado o filtrado
[ OK ]   puerto 2376 cerrado o filtrado

OK: el perímetro de 10.0.2.15 es el diseñado.
```

Caveats: `10.0.2.15` is VirtualBox's default NAT address of the guest, so confirm the run came from a different
machine than the VM (host-only or bridged adapter) if this evidence has to count as an outside view.

`nmap -Pn -sS -p- 10.0.2.15`, as reported, from a second vantage point:

```
PORT   STATE SERVICE
22/tcp open  ssh
(65534 filtered ports)
```

This does **not** match the table above: it shows 80/443 as filtered, while `check_perimeter.sh` found them open.
The two runs most likely came from different places (for example the scan through a VirtualBox NAT with only SSH
port-forwarded, the script from inside the VM or on a host-only network). Until both are repeated from the same
outside machine, with the proxy ports showing as `open` in nmap, the AC-5 verification (`nmap` shows SSH and the
proxy ports) is only half confirmed: the closed side (nothing but SSH leaks) is, the open side is not.
