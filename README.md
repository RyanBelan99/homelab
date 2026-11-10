# 🏠 homelab

A two-node [k3s](https://k3s.io) cluster run as code: one Helm chart, one config
file, one secrets file. Remote access is Tailscale only, with no open router ports.

## 🧱 Stack

| Service | Role |
|---|---|
| Traefik | Front door: routes every app by hostname |
| Pi-hole + unbound | Network DNS and ad blocking, DNS-over-TLS upstream |
| Samba | Network file share |
| Jellyfin | Media server, with free live TV via Dispatcharr |
| Seerr | Request page for movies and shows |
| Radarr, Sonarr, Prowlarr, qBittorrent | Media automation; downloads and indexers behind a VPN kill switch |
| Homepage | Dashboard with live pod status |
| proton-exit | Tailscale exit node that leaves through ProtonVPN |
| Tailscale operator | kubectl over the tailnet, authenticated by Tailscale identity |

**Nodes:** a Raspberry Pi 4 (server, front door) and a MacBook Pro M1 Pro on
Fedora Asahi (worker, media and storage).

## 🗂️ Layout

```
chart/
  values.yaml      central config: network, nodes, paths, every app
  templates/       one file per app, plus shared routes, namespaces and secrets
  files/           scripts mounted into pods
secrets.example.yaml  template for secrets/secrets.yaml (gitignored)
scripts/
  server.sh        server bootstrap, safe to re-run
  worker.sh        worker bootstrap, safe to re-run
docs/
  host-config.md   everything outside Kubernetes
  tailscale-policy.hujson  tailnet access policy
```

## 🌐 Access

Each app gets two names from its `route.host`:

- `<host>.<localDomain>` on the LAN (Pi-hole points the domain at Traefik)
- `https://<host>.<tailnet>.ts.net` remotely, as its own Tailscale Service

Access is granted per app in the tailnet policy: members get Jellyfin, Seerr,
DNS and the ProtonVPN exit node; admins get everything.

## 🚀 Deploy

```bash
cp secrets.example.yaml secrets/secrets.yaml   # fill in
helm upgrade --install homelab chart -f secrets/secrets.yaml -n homelab --create-namespace
```

Change a node, IP, path, image or schedule in `chart/values.yaml` and run the same command.

Preview a change before applying it:

```bash
helm template homelab chart -f secrets/secrets.yaml | kubectl diff -f -
```

## 🔧 Rebuild from scratch

1. Tailscale: apply [`docs/tailscale-policy.hujson`](docs/tailscale-policy.hujson).
2. Server: `sudo scripts/server.sh` (the first run asks for one reboot, then re-run).
3. Worker: `sudo SERVER=<server-ip> K3S_TOKEN=<token> scripts/worker.sh`, then re-run `server.sh`.
4. Deploy the chart, then re-run `server.sh` to publish the Tailscale Services.

Details: [`docs/host-config.md`](docs/host-config.md).

App state lives on the nodes in `paths.config` and `paths.data`, not in git.
