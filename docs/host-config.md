# Host configuration

Everything outside Kubernetes lives in two scripts, one per machine. Both detect
their network, hostname and admin user, so they need no config, and both are safe to re-run.

| Script | Machine | Does |
|---|---|---|
| [`server.sh`](../scripts/server.sh) | Raspberry Pi (Raspberry Pi OS) | Headless and hardened, host DNS pinned off Pi-hole, k3s server, ufw, Tailscale subnet router + exit node, one Tailscale Service per app route |
| [`worker.sh`](../scripts/worker.sh) | MacBook Pro M1 Pro (Fedora Asahi Server) | Laptop-as-server (charge limit, lid, no sleep), data folders, key-only SSH, security updates, k3s agent, power-loss alerts |

Re-run `server.sh` after a worker joins (opens kubelet and flannel to it) and after
adding an app (publishes its Tailscale Service).

## Worker notes

- 16 KiB memory pages: images bundling a 4 KiB jemalloc crash here.
- No hardware transcoding on Linux yet; Jellyfin transcodes on the CPU.
- A drained MacBook stays off until its lid opens, hence the power alerts.

## Tailscale admin console

- Policy: [`tailscale-policy.hujson`](tailscale-policy.hujson).
- DNS: nameserver = server LAN IP, with Override DNS servers and Use with exit node on. HTTPS Certificates on.
- Services: each app route defined on the Services page (tcp:443).

## kubectl

Through the Tailscale operator's API proxy, with no credential on disk:

```bash
tailscale configure kubeconfig tailscale-operator
kubectl auth whoami
```

The first requests after an install can time out while the proxy gets its certificate.
Break-glass: SSH to the server and use its `~/.kube/config`.
