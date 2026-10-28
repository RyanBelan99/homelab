#!/bin/bash
# Phase 2 - install k3s (bundled Traefik disabled: apps/traefik/ installs a pinned one).
# The admin kubeconfig is root-only; docs/host-config.md section 4 has the user copy.
# Run as: sudo bash ~/homelab/scripts/02-install-k3s.sh
set -euo pipefail

curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 600

echo "== waiting for node to be Ready =="
for i in $(seq 1 60); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
  sleep 5
done
k3s kubectl get nodes -o wide
k3s kubectl get pods -A
echo "== DONE =="
