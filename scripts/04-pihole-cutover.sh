#!/bin/bash
# Phase 5 — Pi-hole cutover. THIS STARTS THE DNS DOWNTIME WINDOW (~2-5 min).
# Prereq: image already pre-pulled onto the node (Claude handles that first).
# Run as: sudo bash ~/homelab/scripts/04-pihole-cutover.sh
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "== stopping native Pi-hole (frees ports 53/80/443) =="
systemctl stop pihole-FTL

echo "== deploying Pi-hole to k3s =="
kubectl apply -f /home/rbelan/homelab/apps/pihole/
kubectl -n pihole rollout status deploy/pihole --timeout=300s

echo "== smoke tests against 192.168.0.34 =="
sleep 5
dig +short +time=3 @192.168.0.34 google.com || true
dig +short +time=3 @192.168.0.34 doubleclick.net || true
kubectl -n pihole get pods,svc

echo
echo "OK -> web UI: http://192.168.0.34/admin (password in ~/homelab/secrets/CREDENTIALS.txt)"
echo "     Restore your settings: web UI > Settings > Teleporter > import the .zip in ~/homelab/backups/"
echo
echo "ROLLBACK if broken:"
echo "  kubectl delete -f /home/rbelan/homelab/apps/pihole/ && sudo systemctl start pihole-FTL"
echo
echo "After 1-2 days of stability: sudo systemctl disable pihole-FTL"
