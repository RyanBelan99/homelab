#!/bin/bash
# Phase 6 - Tailscale remote access: subnet router for the LAN + exit node.
# Prereq: docs/tailscale-policy.hujson is saved in the Tailscale admin console
# (tag:homelab must exist before this node can claim it).
# Run as: sudo bash ~/homelab/scripts/05-tailscale.sh
# Or, to skip the browser login, with a one-off pre-approved tag:homelab auth key
# (admin console > Settings > Keys):
#   sudo TS_AUTHKEY=tskey-auth-... bash ~/homelab/scripts/05-tailscale.sh
set -euo pipefail

LAN_CIDR=192.168.0.0/24

echo "== 1/5 install tailscale =="
if command -v tailscale >/dev/null; then
  echo "already installed: $(tailscale version | head -1)"
else
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "== 2/5 IP forwarding (subnet router + exit node) =="
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf

echo "== 3/5 ufw rules for tailscale =="
ufw allow in on tailscale0 comment 'tailscale: tailnet to host + k3s services'
ufw route allow in on tailscale0 out on eth0 comment 'tailscale: subnet route + exit node'
ufw allow 41641/udp comment 'tailscale: direct WireGuard connections'
ufw status numbered

echo "== 4/5 UDP GRO forwarding on eth0 (subnet router throughput) =="
# https://tailscale.com/s/ethtool-config-udp-gro - re-applied by NetworkManager
# every time eth0 comes up, since ethtool settings do not survive a reboot.
apt-get install -y ethtool
cat > /etc/NetworkManager/dispatcher.d/50-tailscale-gro <<'EOF'
#!/bin/sh
[ "$1" = eth0 ] && [ "$2" = up ] && ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/50-tailscale-gro
ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off

echo "== 5/5 join the tailnet =="
# --accept-dns=false keeps the host DNS pin from docs/host-config.md section 3.
# Without it, tailscale points the host at Pi-hole and recreates the circular
# dependency on the Pi-hole pod.
tailscale up ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"} \
  --hostname=centralpi \
  --advertise-tags=tag:homelab \
  --advertise-routes="$LAN_CIDR" \
  --advertise-exit-node \
  --accept-dns=false
tailscale status

echo
echo "== DONE. Tailscale IP: $(tailscale ip -4) =="
echo "Next: admin console > DNS > add that IP as a nameserver + turn on Override DNS servers"
