#!/bin/bash
# Phase 2 — install k3s (Traefik disabled; native Pi-hole still owns 80/443).
# Run as: sudo bash ~/homelab/scripts/02-install-k3s.sh
set -euo pipefail

curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644

echo "== waiting for node to be Ready =="
for i in $(seq 1 60); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
  sleep 5
done
k3s kubectl get nodes -o wide
k3s kubectl get pods -A
echo "== DONE =="
