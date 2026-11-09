#!/bin/bash
# Phase 8 - publish apps as Tailscale Services: one HTTPS name per app,
# https://<app>.<tailnet>.ts.net, with a real certificate, granted per person in
# docs/tailscale-policy.hujson. Safe to re-run; add an app by adding its name below.
#
# Every Service goes through the same front door as the home network: Traefik.
# tailscale serve terminates HTTPS and forwards to Traefik with the original
# Host header, and each app's IngressRoute (apps/*/..-routes.yaml) already
# answers <app>.<tailnet>.ts.net by pattern. So a name below must match the
# first label of that app's route (jellyfin, home, radarr, qbit, pihole, ...).
#
# Prereqs, once per tailnet / per app (admin console):
#   - DNS page: HTTPS Certificates enabled
#   - Services page: the Service defined with port tcp:443 (same name as below)
#   - Access controls: the policy's autoApprovers.services and a grant for it
# Run as: sudo bash ~/homelab/scripts/07-tailscale-services.sh
set -euo pipefail

# Traefik's LoadBalancer on the node; kube-proxy routes it to the Traefik pod.
TRAEFIK=http://192.168.0.34:80

SERVICES=(
  jellyfin   # everyone
  seerr      # everyone
  dispatcharr # admins only, like every name below (see the policy's grants)
  home
  radarr
  sonarr
  prowlarr
  qbit
  pihole
)

for name in "${SERVICES[@]}"; do
  echo "== svc:$name -> Traefik =="
  tailscale serve --service="svc:$name" --https=443 "$TRAEFIK"
done

echo
tailscale serve status
