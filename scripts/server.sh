#!/bin/bash
# Server bootstrap (Raspberry Pi OS): k3s, Tailscale, hardening. Safe to re-run;
# re-run after a worker joins or an app is added. Usage: sudo ./server.sh
# Runs as a systemd job so a dropped SSH session can't interrupt it.
set -euo pipefail

if [ "${1:-}" != --run ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
  systemd-run --unit=homelab-server --collect --setenv=ADMIN="${SUDO_USER:?run with sudo}" \
    /bin/bash "$(readlink -f "$0")" --run
  exec journalctl -f -n 50 -o cat -u homelab-server
fi

VPN_CIDR=10.5.5.0/24              # router WireGuard VPN, allowed like the LAN; empty to skip
POD_CIDR=10.42.0.0/16             # k3s defaults
SERVICE_CIDR=10.43.0.0/16

IFACE=$(ip route show default | awk '{print $5; exit}')
IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
LAN=$(ip -4 route show dev "$IFACE" scope link proto kernel | awk '{print $1; exit}')
echo "== $(hostname): $IP on $IFACE, LAN $LAN, admin $ADMIN =="

echo "== cgroup memory controller =="
CMDLINE=/boot/firmware/cmdline.txt
if ! grep -q cgroup_memory "$CMDLINE"; then
  sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE"
  echo "added; reboot and re-run"
  exit 0
fi

# The host must not resolve through the Pi-hole pod it runs.
echo "== host DNS =="
CONN=$(nmcli -g GENERAL.CONNECTION device show "$IFACE")
nmcli con mod "$CONN" ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1 9.9.9.9" ipv6.ignore-auto-dns yes ipv6.dns ""
nmcli con up "$CONN" >/dev/null

echo "== headless: no Docker, desktop, autologin, Bluetooth, mDNS, printing, remote desktop =="
if command -v docker >/dev/null && [ -z "$(docker ps -aq)$(docker images -q)$(docker volume ls -q)" ]; then
  apt-get purge -y docker-ce docker-ce-cli docker-ce-rootless-extras \
    docker-buildx-plugin docker-compose-plugin docker-model-plugin containerd.io
  rm -rf /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /var/lib/docker /var/lib/containerd
  groupdel docker || true
fi
systemctl set-default multi-user.target
systemctl disable --now lightdm.service bluetooth.service avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
systemctl mask --now cups.service cups.socket cups.path cups-browsed.service
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
for pkg in rpi-connect wayvnc; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then apt-get purge -y "$pkg"; fi
done

echo "== ssh =="
printf 'X11Forwarding no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/20-hardening.conf
sshd -t && systemctl reload ssh

echo "== upgrade =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
apt-get install -y ufw ethtool

echo "== k3s (bundled Traefik off: the chart installs it) =="
if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 600
  until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 5; done
fi
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.kube"
install -m 600 -o "$ADMIN" -g "$ADMIN" /etc/rancher/k3s/k3s.yaml "/home/$ADMIN/.kube/config"
k3s kubectl label node "$(hostname)" svccontroller.k3s.cattle.io/enablelb=true --overwrite

echo "== firewall: LAN and VPN reach only ssh, smb, k3s API, DNS, Traefik =="
for net in $LAN $VPN_CIDR; do
  ufw allow from "$net" to any port 22 proto tcp comment ssh
  ufw allow from "$net" to any port 445 proto tcp comment samba
  ufw allow from "$net" to any port 6443 proto tcp comment 'k3s API'
  ufw allow from "$net" to any port 53 comment dns
  ufw allow from "$net" to any port 80 proto tcp comment traefik
done
ufw allow from "$POD_CIDR" comment 'k3s pods'
ufw allow from "$SERVICE_CIDR" comment 'k3s services'
ufw allow in on cni0 comment 'k3s pod bridge'
for worker in $(k3s kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  ufw allow from "$worker" to any port 10250 proto tcp comment 'k3s agent kubelet'
  ufw allow from "$worker" to any port 8472 proto udp comment 'flannel vxlan'
done

echo "== tailscale: subnet router + exit node =="
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
ufw allow in on tailscale0 comment tailscale
ufw route allow in on tailscale0 out on "$IFACE" comment 'tailscale subnet route + exit node'
ufw allow 41641/udp comment 'tailscale direct'
# Tailscale SNAT is off so pods see real tailnet IPs; masquerade only traffic leaving the LAN interface.
if ! grep -q tailscale-masquerade /etc/ufw/before.rules; then
  sed -i "1i # tailscale-masquerade\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 100.64.0.0/10 -o $IFACE -j MASQUERADE\nCOMMIT\n" /etc/ufw/before.rules
fi
ufw --force enable
ufw reload
# UDP GRO forwarding for subnet-router throughput, re-applied whenever the link comes up.
cat > /etc/NetworkManager/dispatcher.d/50-tailscale-gro <<EOF
#!/bin/sh
[ "\$1" = $IFACE ] && [ "\$2" = up ] && ethtool -K $IFACE rx-udp-gro-forwarding on rx-gro-list off
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/50-tailscale-gro
ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off
# First run prints a login URL here.
tailscale up --hostname="$(hostname)" \
  --advertise-tags=tag:homelab --advertise-routes="$LAN" --advertise-exit-node \
  --snat-subnet-routes=false --accept-dns=false

echo "== tailscale services: one per app route =="
# shellcheck disable=SC2016  # literal backtick in Traefik's Host(`...`) rule
for host in $(k3s kubectl get ingressroute -A -o jsonpath='{.items[*].spec.routes[0].match}' 2>/dev/null \
    | grep -o 'Host(`[^.`]*' | cut -c7- | sort -u); do
  tailscale serve --service="svc:$host" --https=443 "http://$IP:80" \
    || echo "svc:$host: define it on the admin console's Services page, then re-run"
done

[ -f /var/run/reboot-required ] && echo "== done; reboot for the new kernel ==" || echo "== done =="
