#!/bin/bash
# Phase 4 — retire native Samba after the k8s Samba pod is verified working.
# Run as: sudo bash ~/homelab/scripts/03-samba-cutover.sh
set -euo pipefail

systemctl disable --now smbd nmbd winbind
echo "Native Samba stopped and disabled (still installed as fallback)."
echo "Re-enable with: sudo systemctl enable --now smbd nmbd winbind"
