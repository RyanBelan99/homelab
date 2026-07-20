#!/bin/bash
# Phase 1 prep for k3s migration — run as: sudo bash ~/homelab/scripts/01-prep.sh
# Then REBOOT: sudo reboot
set -euo pipefail

echo "== 1/4 Pi-hole Teleporter backup =="
cd /home/rbelan/homelab/backups
pihole-FTL --teleporter
chown rbelan:rbelan pi-hole_*.zip
ls -l pi-hole_*.zip

echo "== 2/4 cgroup flags for k3s =="
CMDLINE=/boot/firmware/cmdline.txt
if grep -q cgroup_memory "$CMDLINE"; then
  echo "cgroup flags already present"
else
  cp "$CMDLINE" "$CMDLINE.bak-$(date +%Y%m%d)"
  sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE"
  echo "added: $(cat "$CMDLINE")"
fi

echo "== 3/4 ufw rules for k3s =="
ufw allow from 192.168.0.0/24 to any port 6443 proto tcp comment 'k3s API from LAN'
ufw allow from 10.42.0.0/16 comment 'k3s pods'
ufw allow from 10.43.0.0/16 comment 'k3s services'
ufw allow in on cni0 comment 'k3s pod bridge'
ufw status numbered

echo "== 4/4 Pin host DNS to public resolvers (break circular dependency on Pi-hole) =="
CONN=$(nmcli -g GENERAL.CONNECTION device show eth0)
echo "eth0 connection: $CONN"
nmcli con mod "$CONN" ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1 9.9.9.9"
nmcli con mod "$CONN" ipv6.ignore-auto-dns yes ipv6.dns ""
nmcli con up "$CONN"
cat /etc/resolv.conf

echo
echo "== DONE. Now reboot: sudo reboot =="
