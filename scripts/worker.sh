#!/bin/bash
# Worker bootstrap (Fedora Asahi on a MacBook): laptop-as-server, data folders,
# k3s agent, hardening, power alerts. Safe to re-run. Keep this SSH session open
# until a fresh one works.
# Usage: sudo SERVER=<server-ip> K3S_TOKEN=<server node-token> ./worker.sh
#   (token: sudo cat /var/lib/rancher/k3s/server/node-token on the server)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

ADMIN=${SUDO_USER:?run with sudo}
POD_CIDR=10.42.0.0/16             # k3s defaults
SERVICE_CIDR=10.43.0.0/16
IP=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<NF; i++) if ($i=="src") print $(i+1)}')
echo "== $(hostname): $IP, admin $ADMIN =="

echo "== laptop as server: 80% charge limit, lid ignored, never sleep =="
echo 80 > /sys/class/power_supply/macsmc-battery/charge_control_end_threshold
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
  > /etc/systemd/logind.conf.d/lid.conf
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl kill -s HUP systemd-logind   # reloads logind config

echo "== data folders =="
mkdir -p /mnt/config /mnt/data/media
if [ ! -d /mnt/data/torrents ]; then
  mkdir /mnt/data/torrents
  chattr +C /mnt/data/torrents      # btrfs: no copy-on-write for torrents; only works while empty
fi
chown "$ADMIN:$ADMIN" /mnt/config /mnt/data /mnt/data/media /mnt/data/torrents
semanage fcontext -a -t container_file_t "/mnt/(config|data)(/.*)?" 2>/dev/null || true
restorecon -R /mnt/config /mnt/data

echo "== ssh: keys only =="
[ -s "/home/$ADMIN/.ssh/authorized_keys" ] || { echo "add an SSH key for $ADMIN first" >&2; exit 1; }
# 10- sorts before Fedora's 50-redhat.conf, and sshd keeps the first value it reads.
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
GSSAPIAuthentication no
PermitRootLogin no
X11Forwarding no
EOF
chmod 600 /etc/ssh/sshd_config.d/10-hardening.conf
restorecon /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload sshd

echo "== daily security updates, no reboots =="
dnf install -y dnf5-plugin-automatic
printf '[commands]\nupgrade_type = security\ndownload_updates = yes\napply_updates = yes\nreboot = never\n' \
  > /etc/dnf/automatic.conf
systemctl enable --now dnf5-automatic.timer

echo "== k3s agent =="
if ! command -v k3s >/dev/null; then
  : "${SERVER:?set SERVER=<server-ip>}" "${K3S_TOKEN:?set K3S_TOKEN}"
  firewall-cmd --permanent --zone=trusted --add-source="$POD_CIDR" --add-source="$SERVICE_CIDR" --add-source="$SERVER/32"
  firewall-cmd --reload
  VERSION=$(curl -sk "https://$SERVER:6443/version" | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p')
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$VERSION" K3S_URL="https://$SERVER:6443" \
    K3S_TOKEN="$K3S_TOKEN" sh -s - agent --node-ip "$IP"
  echo "joined; re-run server.sh so the server's firewall admits this node"
fi

echo "== power alerts: Telegram message on AC loss (a drained MacBook stays off until its lid opens) =="
if [ ! -f /etc/power-alert.conf ]; then
  read -rsp "Telegram bot token: " TOKEN; echo
  read -rp "Telegram chat ID: " CHAT
  install -m 600 /dev/null /etc/power-alert.conf
  printf 'TELEGRAM_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$TOKEN" "$CHAT" > /etc/power-alert.conf
fi
cat > /usr/local/bin/power-alert <<'EOF'
#!/bin/bash
# Run every minute by power-alert.timer; "power-alert test" sends a test message.
set -euo pipefail
source /etc/power-alert.conf
send() {
  curl -fsS -m 10 -o /dev/null "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1"
}
[ "${1:-}" = test ] && { send "🔌 $(hostname) power alerts are on."; exit 0; }

AC=$(cat /sys/class/power_supply/macsmc-ac/online)
PCT=$(cat /sys/class/power_supply/macsmc-battery/capacity)
STATE=/run/power-alert.state
read -r LAST_AC LAST_SENT 2>/dev/null < "$STATE" || { LAST_AC=1; LAST_SENT=0; }
NOW=$(date +%s)
if [ "$AC" = 0 ] && { [ "$LAST_AC" = 1 ] || [ $((NOW - LAST_SENT)) -ge 1800 ]; }; then
  send "⚠️ $(hostname) is on battery (${PCT}%). At empty it stays off until the lid opens."
  LAST_SENT=$NOW
elif [ "$AC" = 1 ] && [ "$LAST_AC" = 0 ]; then
  send "✅ $(hostname) power restored, battery at ${PCT}%."
fi
echo "$AC $LAST_SENT" > "$STATE"
EOF
chmod 755 /usr/local/bin/power-alert
printf '[Unit]\nDescription=Telegram alert on AC power loss\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/power-alert\n' \
  > /etc/systemd/system/power-alert.service
printf '[Unit]\nDescription=Check AC power every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=5s\n\n[Install]\nWantedBy=timers.target\n' \
  > /etc/systemd/system/power-alert.timer
systemctl daemon-reload
systemctl enable --now power-alert.timer

echo "== done =="
