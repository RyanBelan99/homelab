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
- Funnel: only Jellyfin is public, at `watch.<tailnet>.ts.net` (operator Ingress, `apps.jellyfin.funnel`). New Funnel names take about 2 minutes to reach the public relays.

## App settings outside the chart

The apps keep these in their own config files (under `paths.config`), not in Helm values.
Re-apply them after wiping an app's config.

| App | Setting | Value | Why |
|---|---|---|---|
| Jellyfin | Networking > Known proxies | `10.42.0.0/16`, `192.168.0.34` | Trust Traefik's and `tailscale serve`'s `X-Forwarded-For`, so Jellyfin sees the real client IP |
| Jellyfin | Networking > LAN networks | `192.168.0.0/24` | Only the home LAN is local; tailnet clients (100.x) count as remote |
| Jellyfin | Playback > Internet streaming bitrate limit | 7.5 Mbps | Fits the ~10 Mbps home upload; 1080p is kept from about 7 Mbps up (5 Mbps drops to 720p) |
| Jellyfin | Transcoding > Throttle transcodes, Delete segments | Off | Let streams prepare to the end instead of pausing 3 minutes ahead |
| qBittorrent | Speed > Global upload limit | 60 KiB/s | Seeding otherwise takes ~2 Mbps of the upload remote streams need |

At home, use `jellyfin.home.arpa`: tailnet clients are always remote, so `ts.net` gets the cap even on the LAN.

## kubectl

Through the Tailscale operator's API proxy, with no credential on disk:

```bash
tailscale configure kubeconfig tailscale-operator
kubectl auth whoami
```

The first requests after an install can time out while the proxy gets its certificate.
Break-glass: SSH to the server and use its `~/.kube/config`.
