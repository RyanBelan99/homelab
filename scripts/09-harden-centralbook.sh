#!/bin/bash
# centralbook - the two host gaps from the 2026-11-03 audit:
#   1. SSH accepted passwords (the Pi is key-only). Now key-only, no root login.
#   2. No automatic updates. Now Fedora security updates install daily, without
#      rebooting: k3s and the media apps stay up, and a kernel update waits for
#      the next planned reboot.
# The console login at the keyboard keeps its password; only SSH changes.
# Run as: sudo bash ~/09-harden-centralbook.sh   (keep this SSH session open
# until a second `ssh rbelan@192.168.0.128` works)
set -euo pipefail

USER_HOME=/home/rbelan

echo "== 1/2 ssh: keys only =="
# Refuse to lock ourselves out: a key must already be authorized.
if [ ! -s "$USER_HOME/.ssh/authorized_keys" ]; then
  echo "No SSH key in $USER_HOME/.ssh/authorized_keys; add one before disabling passwords." >&2
  exit 1
fi
# sshd keeps the first value it reads, and drop-ins load in name order, so 10-
# wins over Fedora's own 50-redhat.conf.
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
GSSAPIAuthentication no
PermitRootLogin no
X11Forwarding no
EOF
chmod 600 /etc/ssh/sshd_config.d/10-hardening.conf
restorecon /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t                      # config check; set -e stops here if it's invalid
systemctl reload sshd        # reload keeps existing sessions open
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|gssapiauthentication) '

echo "== 2/2 automatic security updates =="
dnf install -y dnf5-plugin-automatic
cat > /etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
reboot = never
EOF
systemctl enable --now dnf5-automatic.timer
systemctl list-timers dnf5-automatic.timer --no-pager
