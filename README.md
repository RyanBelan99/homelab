# CentralPI homelab

Source of truth for the services running on **CentralPI** (Raspberry Pi 4B), a
single-node [k3s](https://k3s.io) Kubernetes cluster. Every service runs in its
own container. The cluster serves the LAN on the Pi's IP, `192.168.0.34`.

| Service | Namespace | Ports | What it is |
|---------|-----------|-------|------------|
| Pi-hole | `pihole`  | 53 (DNS), 80/443 (admin UI) | Network-wide DNS + ad blocking |
| Samba   | `nas`     | 445 (SMB) | `NetworkStorage` file share (`~/shared/nas`) |

## Layout

```
apps/        Kubernetes manifests, one folder per service
  pihole/    namespace, secret, PVC, deployment, service
  samba/     namespace, secret, deployment, service
scripts/     the sudo-required setup/cutover scripts (01–04), run in order
docs/        host-config.md — the non-Kubernetes host settings (cgroups, ufw, DNS)
secrets/     real credentials — GITIGNORED, never committed
backups/     Pi-hole Teleporter exports — GITIGNORED
```

## Secrets — read this before cloning elsewhere

Real passwords are **not** in git. Each service has a committed
`10-secret.yaml.example` (placeholder values) and a gitignored `10-secret.yaml`
(the real one, present only on this Pi). On a fresh clone you must recreate the
real secrets:

```bash
cp apps/pihole/10-secret.yaml.example apps/pihole/10-secret.yaml   # then edit in a real password
cp apps/samba/10-secret.yaml.example  apps/samba/10-secret.yaml    # then edit in a real password
```

`kubectl apply -f apps/<svc>/` applies `10-secret.yaml` and ignores the
`.example` (kubectl only reads `.yaml/.yml/.json`), so the placeholder can never
overwrite your live Secret.

The current live passwords are in `secrets/CREDENTIALS.txt` (also gitignored).

## Everyday commands

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # once per shell (or add to ~/.bashrc)

kubectl get pods -A                            # everything running
kubectl apply -f apps/pihole/                  # apply Pi-hole changes
kubectl apply -f apps/samba/                   # apply Samba changes
kubectl -n pihole rollout restart deploy/pihole
```

## Rollback to native (emergency)

The pre-migration native services are still installed but disabled, as a fallback:

```bash
# Pi-hole
kubectl delete -f apps/pihole/ && sudo systemctl start pihole-FTL
# Samba
kubectl delete -f apps/samba/ && sudo systemctl enable --now smbd nmbd winbind
```

## Rebuilding from scratch

See `docs/host-config.md` for the host-level prerequisites, then run
`scripts/01-prep.sh` → reboot → `02-install-k3s.sh`, recreate the secrets (above),
and `kubectl apply -f apps/pihole/ -f apps/samba/`.
