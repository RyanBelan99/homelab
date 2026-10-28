# CentralPI homelab

Source of truth for the services running on **CentralPI** (Raspberry Pi 4B), a
single-node [k3s](https://k3s.io) Kubernetes cluster. Every service runs in its
own container. The cluster serves the LAN on the Pi's IP, `192.168.0.34`.

Web apps are reached by name through [Traefik](https://traefik.io) on port 80:
Pi-hole answers every `*.home.arpa` name with `192.168.0.34`, and Traefik routes
by hostname. Only DNS, SMB, Traefik and Jellyfin's direct port (for TV apps and
family accounts) are open on the node.

| Service | Namespace | Address | What it is |
|---------|-----------|---------|------------|
| Traefik | `traefik` | :80 | Reverse proxy for every `*.home.arpa` name |
| Pi-hole | `pihole`  | :53 (DNS), http://pihole.home.arpa/admin/ | Network-wide DNS + ad blocking |
| Samba   | `nas`     | :445 (SMB) | `NetworkStorage` file share (`~/shared/nas`) |
| Jellyfin | `media`  | http://jellyfin.home.arpa, :8096 | Media server |
| qBittorrent + gluetun | `media` | http://qbit.home.arpa | Download client, all traffic through a VPN sidecar |
| Radarr / Sonarr | `media` | http://radarr.home.arpa / http://sonarr.home.arpa | Movie / TV automation |
| Prowlarr + gluetun | `media` | http://prowlarr.home.arpa | Indexer manager for Radarr and Sonarr, searches through its own VPN sidecar |
| Homepage | `dashboard` | http://home.home.arpa | Dashboard |
| proton-exit (Tailscale + gluetun) | `vpn-exit` | tailnet only | Tailscale exit node whose traffic leaves through ProtonVPN |

## Layout

```
apps/          Kubernetes manifests, one folder per service
  traefik/     namespace + pinned Traefik HelmChart (reverse proxy on :80)
  pihole/      namespace, secret, PVC, deployment, services, ingress
  nas/samba/   namespace, secret, deployment
  media/       namespace, VPN secret, one file per app (deployment + service), ingresses
  dashboard/   Homepage, ingress
  vpn-exit/    proton-exit: Tailscale exit node behind a gluetun ProtonVPN tunnel
scripts/       the sudo-required setup/cutover scripts (01-06), run in order
docs/          host-config.md - the non-Kubernetes host settings (cgroups, ufw, DNS, Tailscale)
               tailscale-policy.hujson - tailnet access rules (pasted into the admin console)
secrets/       real credentials - GITIGNORED, never committed
backups/       Pi-hole Teleporter exports - GITIGNORED
```

The media apps keep their state in hostPath folders on the Pi, not in git:
`/mnt/config/<app>` (settings and databases) and `/mnt/data` (`torrents/` and
`media/` on one filesystem, so Radarr and Sonarr can hardlink).

## Remote access

[Tailscale](https://tailscale.com) on the host (not in k3s) makes CentralPI a
subnet router for `192.168.0.0/24` and an exit node. Away from home, tailnet
devices use the same LAN URLs and Pi-hole as their DNS. No router ports are
forwarded. Family accounts can reach Jellyfin (`:8096`) only. Setup:
`scripts/05-tailscale.sh` and `docs/host-config.md` section 6.

Two exit nodes, picked per device in the Tailscale app: `centralpi` (websites
see the home IP) and `proton-exit` (`apps/vpn-exit/`, websites see a ProtonVPN
IP, with a kill switch if the tunnel drops).

## Secrets - read this before cloning elsewhere

Real passwords are **not** in git. Each service has a committed
`10-secret.yaml.example` (placeholder values) and a gitignored `10-secret.yaml`
(the real one). On a fresh clone you must recreate the real secrets:

```bash
cp apps/pihole/10-secret.yaml.example    apps/pihole/10-secret.yaml      # then edit in a real password
cp apps/nas/samba/10-secret.yaml.example apps/nas/samba/10-secret.yaml   # then edit in a real password
cp apps/media/10-secret.yaml.example     apps/media/10-secret.yaml       # then fill in two WireGuard configs (qBittorrent, Prowlarr)
cp apps/vpn-exit/10-secret.yaml.example  apps/vpn-exit/10-secret.yaml    # then fill in a third WireGuard config + a Tailscale auth key
```

`kubectl apply -f apps/<svc>/` applies `10-secret.yaml` and ignores the
`.example` (kubectl only reads `.yaml/.yml/.json`), so the placeholder can never
overwrite your live Secret.

The current live passwords are in `secrets/CREDENTIALS.txt` (also gitignored).

## Everyday commands

```bash
export KUBECONFIG=~/.kube/pi-config            # on the Mac (on the Pi: ~/.kube/config)

kubectl get pods -A                            # everything running
kubectl apply -f apps/pihole/                  # apply Pi-hole changes
kubectl apply -f apps/nas/samba/               # apply Samba changes
kubectl apply -f apps/media/                   # apply the media stack
kubectl apply -f apps/traefik/                 # apply Traefik (pinned Helm chart)
kubectl apply -f apps/vpn-exit/                # apply the proton-exit exit node
kubectl -n pihole rollout restart deploy/pihole
```

## Rollback to native (emergency)

The pre-migration native services are still installed but disabled, as a fallback:

```bash
# Pi-hole
kubectl delete -f apps/pihole/ && sudo systemctl start pihole-FTL
# Samba
kubectl delete -f apps/nas/samba/ && sudo systemctl enable --now smbd nmbd winbind
```

## Rebuilding from scratch

See `docs/host-config.md` for the host-level prerequisites, then run
`scripts/01-prep.sh` → reboot → `02-install-k3s.sh`, recreate the secrets (above),
create the `/mnt/data` and `/mnt/config` folders (owned by uid 1000), and
`kubectl apply -f apps/traefik/ -f apps/pihole/ -f apps/nas/samba/ -f apps/media/ -f apps/dashboard/ -f apps/vpn-exit/`.
