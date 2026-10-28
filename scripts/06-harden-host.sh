#!/bin/bash
# Phase 7 - host hardening (security audit 2026-10-28, quick wins part B).
# Removes unused Docker, boots without the desktop, stops Bluetooth/CUPS/avahi,
# tightens SSH and ufw, makes the k3s admin kubeconfig root-only, and applies
# pending updates. Reboot afterwards (new kernel), ideally while you are home.
#
# Run as: sudo bash ~/homelab/scripts/06-harden-host.sh
# It starts itself as a background systemd job, so a dropped SSH/Tailscale
# session cannot kill it halfway through the upgrades, and then follows its log.
# Ctrl-C only stops watching. Re-attach with: journalctl -f -o cat -u harden-host
set -euo pipefail

if [ "${1:-}" != "--run" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
  if systemctl is-active --quiet harden-host; then
    echo "Already running. Follow it with: journalctl -f -o cat -u harden-host"
    exit 1
  fi
  systemd-run --unit=harden-host --collect /bin/bash "$(readlink -f "$0")" --run
  echo "Started background job harden-host. Following its log (Ctrl-C only stops watching):"
  exec journalctl -f -n 100 -o cat -u harden-host
fi

ADMIN=rbelan
# Home LAN and the router's WireGuard VPN.
NETS="192.168.0.0/24 10.5.5.0/24"

echo "== 1/6 remove Docker (unused; k3s runs its own containerd) =="
if command -v docker >/dev/null; then
  if [ -n "$(docker ps -aq 2>/dev/null)$(docker images -q 2>/dev/null)$(docker volume ls -q 2>/dev/null)" ]; then
    echo "Docker has containers, images or volumes: skipping its removal"
  else
    systemctl disable --now docker.service docker.socket containerd.service || true
    apt-get purge -y docker-ce docker-ce-cli docker-ce-rootless-extras \
      docker-buildx-plugin docker-compose-plugin docker-model-plugin containerd.io
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    # Docker's own data dirs. k3s keeps its containerd under /var/lib/rancher/k3s.
    rm -rf /var/lib/docker /var/lib/containerd
    gpasswd -d "$ADMIN" docker || true
    groupdel docker || true
  fi
else
  echo "Docker is not installed"
fi

echo "== 2/6 boot without the desktop; stop Bluetooth, printing, mDNS =="
systemctl set-default multi-user.target
systemctl disable --now lightdm.service
# No automatic console login either: a keyboard on the Pi must not get a shell.
if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
  rm /etc/systemd/system/getty@tty1.service.d/autologin.conf
  systemctl daemon-reload
  systemctl restart getty@tty1.service
fi
systemctl disable --now bluetooth.service avahi-daemon.service avahi-daemon.socket
# cups-browsed has had remote-code-execution bugs; keep the whole stack off.
systemctl mask --now cups.service cups.socket cups.path cups-browsed.service
# Raspberry Pi Connect (remote shell and screen sharing through Raspberry Pi's
# cloud, bypassing Tailscale and ufw) and the VNC server it uses: unused here.
for pkg in rpi-connect wayvnc; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then apt-get purge -y "$pkg"; fi
done

echo "== 3/6 SSH: no X11 forwarding, no root login =="
cat > /etc/ssh/sshd_config.d/20-hardening.conf <<'EOF'
# scripts/06-harden-host.sh. Drop-ins are read before the main sshd_config,
# and sshd keeps the first value it sees, so these win.
X11Forwarding no
PermitRootLogin no
EOF
sshd -t
systemctl reload ssh

echo "== 4/6 firewall: LAN and router VPN reach only the services they use =="
# Add the specific rules before removing the broad ones, so nothing is cut off.
# DNS, Traefik and Jellyfin are Kubernetes services: their traffic is forwarded
# to pods, not delivered to the host, so these allows are a safety net only.
for net in $NETS; do
  ufw allow from "$net" to any port 22 proto tcp comment 'ssh'
  ufw allow from "$net" to any port 445 proto tcp comment 'samba'
  ufw allow from "$net" to any port 6443 proto tcp comment 'k3s API (kubectl)'
  ufw allow from "$net" to any port 53 comment 'pi-hole DNS'
  ufw allow from "$net" to any port 80 proto tcp comment 'traefik'
  ufw allow from "$net" to any port 8096 proto tcp comment 'jellyfin'
done
# Now the LAN no longer reaches kubelet (10250), flannel VXLAN (8472/udp),
# NetBIOS, WS-Discovery/LLMNR or the kube-proxy health-check ports.
for net in $NETS; do
  ufw delete allow from "$net" || true
done
ufw status numbered

echo "== 5/6 k3s admin kubeconfig: root-only =="
UNIT=/etc/systemd/system/k3s.service
if grep -q "'644'" "$UNIT"; then
  [ "$(grep -c "'644'" "$UNIT")" -eq 1 ] || { echo "unexpected k3s unit, not editing"; exit 1; }
  sed -i "s/'644'/'600'/" "$UNIT"
  systemctl daemon-reload   # k3s picks it up on its next restart (the reboot)
fi
chmod 600 /etc/rancher/k3s/k3s.yaml
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.kube"
install -m 600 -o "$ADMIN" -g "$ADMIN" /etc/rancher/k3s/k3s.yaml "/home/$ADMIN/.kube/config"
sed -i 's#^export KUBECONFIG=/etc/rancher/k3s/k3s.yaml$#export KUBECONFIG=$HOME/.kube/config#' "/home/$ADMIN/.bashrc"
ls -l /etc/rancher/k3s/k3s.yaml "/home/$ADMIN/.kube/config"

echo "== 6/6 apply pending updates =="
# Finish any package setup an earlier run left half-done (for example after a
# reboot that interrupted it); a no-op otherwise.
dpkg --configure -a
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
# Config files left behind by packages removed earlier ("rc" in dpkg -l).
LEFTOVER=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"{print $2}')
if [ -n "$LEFTOVER" ]; then apt-get purge -y $LEFTOVER; fi

echo
if [ -f /var/run/reboot-required ]; then
  echo "== DONE. A reboot is needed for the new kernel: sudo reboot (best while you are home) =="
else
  echo "== DONE =="
fi
cat <<'EOF'
Undo, if needed:
  firewall:  sudo ufw allow from 192.168.0.0/24 && sudo ufw allow from 10.5.5.0/24
  desktop:   sudo systemctl set-default graphical.target && sudo systemctl enable --now lightdm
  printing:  sudo systemctl unmask cups.service cups.socket cups.path cups-browsed.service
  ssh:       sudo rm /etc/ssh/sshd_config.d/20-hardening.conf && sudo systemctl reload ssh
  k3s mode:  sudo sed -i "s/'600'/'644'/" /etc/systemd/system/k3s.service && sudo systemctl daemon-reload
EOF
