# Host configuration

Everything outside Kubernetes lives in two scripts, one per machine. Both detect
their network, hostname and admin user, so they need no config, and both are safe to re-run.

| Script | Machine | Does |
|---|---|---|
| [`server.sh`](../scripts/server.sh) | Raspberry Pi (Raspberry Pi OS or Ubuntu Server) | Headless and hardened, host DNS pinned off Pi-hole, k3s server, ufw, Tailscale subnet router + exit node, one Tailscale Service per app route |
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
- Services: each app route defined on the Services page (tcp:443). Add a new Service to the policy and the Services page *before* `tailscale serve` advertises it; a host that advertised too early stays unapproved until `sudo tailscale serve clear svc:<name>` and the serve command again.
- Funnel: off. Jellyfin's public path is the router forward to Traefik (see Public HTTPS); Funnel's shared relays stalled heavy streams.

## Public HTTPS

- Name: `secrets.publicDomain` on DuckDNS (`public.provider`), kept on the home IP by ddns-updater. Certificates come from Let's Encrypt by DNS-01, so port 80 stays closed.
- Router: forward external TCP 443 to the server's LAN IP, port 443. No port 80, no UPnP.
- At home Pi-hole answers the name with the server's LAN IP; tailnet devices reach it through the subnet route (`traefik-lan` grant).
- Moving from the staging resolver to `le`: delete `/data/acme-le-staging.json` in the Traefik pod and restart it, or Traefik keeps serving the staging certificate.

## CrowdSec

- Agents (one per node) read Traefik's JSON access log and Jellyfin's and Seerr's failed sign-ins; LAPI on the server keeps the ban list and shares attacker IPs with CrowdSec's free community blocklist.
- The `crowdsec` middleware runs first on the public routes only. Home LAN, pods and the tailnet (`apps.crowdsec.trusted`) are never checked or banned.
- Fail-open (`updateMaxFailure: -1`): if LAPI is down, Traefik keeps enforcing the last ban list it pulled.
- Traefik downloads the bouncer plugin from GitHub when it starts; if that fails, the public names return 404 until Traefik restarts (LAN and tailnet routes are unaffected).
- Seerr v3 logs "Failed sign-in attempt", which the hub's Jellyseerr parser doesn't know; `homelab/seerr-logs` in `crowdsec.yaml` covers it.
- Homepage's CrowdSec widget signs in as the machine `homepage`, with the password the chart keeps in `homepage-widgets`. The machine lives in LAPI's database, so after a fresh CrowdSec install register it again:
  `kubectl -n dashboard get secret homepage-widgets -o jsonpath='{.data.HOMEPAGE_VAR_CROWDSEC_PASSWORD}' | base64 -d | kubectl -n crowdsec exec -i deploy/crowdsec-lapi -- sh -c 'cscli machines add homepage --password "$(cat)" --force -f /dev/null'`
- Useful commands: `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list`, `... cscli alerts list`, `... cscli decisions delete --ip <ip>`.

## App settings outside the chart

The apps keep these in their own config files (under `paths.config`), not in Helm values.
Re-apply them after wiping an app's config.

| App | Setting | Value | Why |
|---|---|---|---|
| Jellyfin | Networking > Known proxies | `10.42.0.0/16`, `192.168.0.34` | Trust Traefik's and `tailscale serve`'s `X-Forwarded-For`, so Jellyfin sees the real client IP |
| Jellyfin | Networking > LAN networks | `192.168.0.0/24` | Only the home LAN is local; tailnet clients (100.x) count as remote |
| Jellyfin | Playback > Internet streaming bitrate limit | 7.5 Mbps | Fits the ~10 Mbps home upload; 1080p is kept from about 7 Mbps up (5 Mbps drops to 720p) |
| Jellyfin | Transcoding > Throttle transcodes, Delete segments | Off | Let streams prepare to the end instead of pausing 3 minutes ahead |
| Jellyfin | Transcoding > Allow encoding in HEVC, Encoder preset | On, veryfast | Software x265 runs ~2.2x real time at 1080p on centralbook; HEVC gives better quality at the same remote bitrate |
| Seerr | Settings > General > Application URL | `https://seerr.<publicDomain>` | Links in emails and the app point at the public name |
| Seerr | Settings > General > Enable Proxy Support | On | Trust Traefik's `X-Forwarded-For`, so Seerr logs real client IPs |
| Seerr | Settings > Jellyfin > External URL | `https://<publicDomain>` | "Play on Jellyfin" opens the public name, which works everywhere |
| qBittorrent | Web UI > Bypass authentication for clients in whitelisted IP subnets | On, `10.42.0.0/24` (`network.serverPodCIDR`) | Traefik's range, so Keycloak sign-in is the only login; Radarr and Sonarr (on the worker) still use the password. Re-check after Cilium or a node rebuild changes pod ranges |
| Dispatcharr | Settings > Reverse Proxy Auth | On, header `X-Auth-Request-Preferred-Username` | Signs in the Dispatcharr user matching your Keycloak username; trusted only from `DISPATCHARR_TRUSTED_PROXIES` (set in the chart) |
| qBittorrent | Speed > Global upload limit | 60 KiB/s | Seeding otherwise takes ~2 Mbps of the upload remote streams need |
| Radarr, Sonarr, Prowlarr | Settings > General > Authentication | External | Keycloak (forward auth) is the only sign-in; the API still needs its key |
| Keycloak | homelab realm > Users | Your user, in group `admins`, email verified | The realm import creates groups and clients, not users; the master realm is only for administering Keycloak |
| Keycloak | Each app client > Dedicated scope > Full scope allowed | Off | Keeps sessions under oauth2-proxy's 4 KB cookie; a fresh realm import already sets it |

At home, use `jellyfin.home.arpa`: tailnet clients are always remote, so `ts.net` gets the cap even on the LAN.

## Keycloak

- Admin console: `https://auth.<tailnet>.ts.net/admin/` (admins only, never public). Its database and bootstrap passwords and every client secret are generated by Helm on first install and kept in the `keycloak-secrets` and `oidc-clients` Secrets.
- Apps behind sign-in are listed in `apps.keycloak.sso.protect`. One shared oauth2-proxy (namespace `auth`) guards them all with a single cookie for the tailnet domain, using the `sso.client` Keycloak client (`home`); sign-in completes at `home.<tailnet>/oauth2/callback` and returns to the app. Adding an app needs only its name in `protect`.
- The realm still has the older per-app clients (`prowlarr`, `radarr`, `sonarr`, `qbit`, `pihole`, `dispatcharr`); nothing uses them, so they can be deleted in the console.

## kubectl

Through the Tailscale operator's API proxy, with no credential on disk:

```bash
tailscale configure kubeconfig tailscale-operator
kubectl auth whoami
```

The first requests after an install can time out while the proxy gets its certificate.
Break-glass: SSH to the server and use its `~/.kube/config`.
