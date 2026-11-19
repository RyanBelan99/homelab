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
- After a node reboot an agent pod comes back with its old name and can't re-register ("user already exist", [helm-charts#252](https://github.com/crowdsecurity/helm-charts/issues/252)). The `crowdsec-agent-watchdog` CronJob deletes any agent whose registration has failed 3 times, every 5 minutes, so it returns under a new name; LAPI deletes registrations unused for 7 days. By hand: `kubectl -n crowdsec delete pod -l type=agent`.
- Seerr v3 logs "Failed sign-in attempt", which the hub's Jellyseerr parser doesn't know; `homelab/seerr-logs` in `crowdsec.yaml` covers it.
- Homepage's CrowdSec widget signs in as the machine `homepage`, with the password the chart keeps in `homepage-widgets`. The machine lives in LAPI's database, so after a fresh CrowdSec install register it again:
  `kubectl -n dashboard get secret homepage-widgets -o jsonpath='{.data.HOMEPAGE_VAR_CROWDSEC_PASSWORD}' | base64 -d | kubectl -n crowdsec exec -i deploy/crowdsec-lapi -- sh -c 'cscli machines add homepage --password "$(cat)" --force -f /dev/null'`
- Each ban CrowdSec decides itself sends a Telegram message (IP, country, network, scenario; bursts within 30 s share one message). Community blocklist entries don't. The text is `telegram.yaml` in `crowdsec.yaml`; test it with `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli notifications test telegram`.
- Useful commands: `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list`, `... cscli alerts list`, `... cscli decisions delete --ip <ip>`.

## Observability

- `grafana.<tailnet>` (admins, Keycloak sign-in, no second login): node, Traefik and CrowdSec dashboards, pinned in `apps.observability.dashboards`.
- One pod (`observability` namespace) runs Prometheus (15 days, 4 GB cap), Grafana and kube-state-metrics; a node-exporter runs on each node. Prometheus scrapes the node-exporters and the `metrics` ports of Traefik and CrowdSec.
- Alerts are Grafana rules in `apps.observability.alerts`, sent to Telegram (`secrets.telegram`). Each rule's `summary` is its message line (`$values.A.Value` is the measured number); the Telegram layout around it is the contact point's `message` in `observability.yaml`. Grafana shows provisioned rules read-only: edit them here, then `helm upgrade` and `kubectl -n observability rollout restart deploy/observability`.
- Add `svc:grafana` to the Services page before `server.sh` serves it.

## Storage and network policies

- App folders under `/mnt/config` and `/mnt/data` are node-bound volumes (`storage.volumes` in values, `storage.yaml`): a local PersistentVolume pinned to the node that holds the folder, pre-bound to one claim. Data stays in place. Add a folder there, not as a `hostPath`. Moving an app to another node is explicit: scale it to 0, copy the folder, change its entry, scale up.
- Each namespace with apps denies incoming traffic except the flows listed in `networkpolicies.yaml` (egress stays open). SABnzbd only accepts Traefik, Homepage, Radarr, Sonarr and Prowlarr. A new app that another app or Homepage calls needs its flow added there.
- If `helm upgrade` fails with "may not specify more than 1 volume type", an old `kubectl apply` still owns that volume: replace it with a JSON patch (`kubectl patch --type=json`, remove the old field and add the new one), then upgrade again.

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
| Dispatcharr | Settings > Reverse Proxy Auth | On, header `X-Auth-Request-Preferred-Username` | Signs in the Dispatcharr user matching your Keycloak username; trusted only from `DISPATCHARR_TRUSTED_PROXIES` (set in the chart) |
| SABnzbd | Config > Servers | Your Usenet provider, SSL on port 563, connections at or under the plan's limit | The provider's login lives here, not in the chart |
| SABnzbd | Config > Folders | Temporary `/data/usenet/incomplete`, Completed `/data/usenet/complete` | Same `/data` mount as Radarr and Sonarr, so imports are a rename, not a copy |
| SABnzbd | Config > Categories | `movies` and `tv`, both folder `Default` | Radarr and Sonarr each send their category and import only their own downloads |
| SABnzbd | Config > Special > `host_whitelist` | `sabnzbd, sabnzbd.media.svc.cluster.local, sabnzbd.<tailnet>.ts.net` | SABnzbd refuses hostnames it doesn't know: Radarr and Sonarr use the cluster name, the browser the tailnet name |
| SABnzbd | Config > General > Security | No username or password | Keycloak (forward auth) is the only sign-in; Radarr, Sonarr and Homepage use the API key |
| SABnzbd | Config > Special > `local_ranges` | `10.42.0.0/16, 100.64.0.0/10` | SABnzbd checks the browser's IP in `X-Forwarded-For`, and tailnet IPs aren't private ranges; without this the tailnet name shows "Refused connection". The API can't set it: use the page, or edit `sabnzbd.ini` and restart the pod |
| SABnzbd | Config > Servers > Articles per request | 8 | Newshosting answers in ~280 ms through the tunnel; pipelining keeps the connections busy |
| Radarr, Sonarr | Settings > Download Clients | SABnzbd at `sabnzbd.media.svc.cluster.local:8080`, category `movies` (Radarr) or `tv` (Sonarr) | The only download client |
| Prowlarr | Indexers | altHUB and NinjaCentral (Newznab), no torrent indexers, no indexer proxies | Prowlarr syncs them to Radarr and Sonarr; Usenet indexers use an API key, so no Cloudflare solver is needed |
| Radarr, Sonarr | Settings > Profiles > HD-1080p | TRaSH tiers (WEB and Bluray groups); `x265 (HD)` custom format at -10000 | 1080p x265 is almost always a re-encode of a WEB-DL, and 10-bit HEVC makes some Jellyfin clients transcode. The format matches `[xh][ ._-]?265\|\bHEVC` in the title, except 2160p |
| Radarr, Sonarr | Settings > Media Management | Import extra files `srt,ass,ssa,sub,idx`; delete empty folders on | Keeps subtitles that come as separate files; cleans up after upgrades |
| Radarr, Sonarr, Prowlarr | Settings > General > Authentication | External | Keycloak (forward auth) is the only sign-in; the API still needs its key |
| Keycloak | homelab realm > Users | Your user, in group `admins`, email verified | The realm import creates groups and clients, not users; the master realm is only for administering Keycloak |
| Keycloak | Each app client > Dedicated scope > Full scope allowed | Off | Keeps sessions under oauth2-proxy's 4 KB cookie; a fresh realm import already sets it |

SABnzbd's own Restart (page or API) can leave it stopped inside the linuxserver image (s6 doesn't bring back the re-spawned process); restart the pod instead: `kubectl -n media rollout restart deploy/sabnzbd`.

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
