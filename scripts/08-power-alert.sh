#!/bin/bash
# centralbook - Telegram alert when the MacBook loses (or regains) AC power.
# A closed-lid MacBook that drains its battery shuts down cleanly but stays off
# until someone opens the lid, so the alert is what buys time to plug it back in.
# Every minute a timer compares AC state with the last run and messages a
# Telegram bot chat on a change, plus a reminder every 30 minutes on battery.
#
# The bot token is a secret: it is prompted for (not passed on the command line)
# and kept root-only in /etc/power-alert.conf, never in this public repo.
# Prereq: a bot from @BotFather, and your chat ID (message the bot once, then
# open https://api.telegram.org/bot<token>/getUpdates and read message.chat.id).
# Run as: sudo bash ~/homelab/scripts/08-power-alert.sh
set -euo pipefail

echo "== 1/3 config =="
read -rsp "Telegram bot token: " TELEGRAM_TOKEN; echo
read -rp "Telegram chat ID: " TELEGRAM_CHAT_ID
install -m 600 /dev/null /etc/power-alert.conf
printf 'TELEGRAM_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT_ID" > /etc/power-alert.conf

echo "== 2/3 check script =="
cat > /usr/local/bin/power-alert <<'EOF'
#!/bin/bash
# Called every minute by power-alert.timer, or with "test" to send a test
# message. State lives in /run, so a reboot starts fresh (and a boot on battery
# alerts right away).
set -euo pipefail
source /etc/power-alert.conf

send() {
  curl -fsS -m 10 -o /dev/null "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$1"
}

if [ "${1:-}" = test ]; then
  send "🔌 centralbook power alerts are on. Unplug the charger to test."
  exit 0
fi

AC=$(cat /sys/class/power_supply/macsmc-ac/online)
PCT=$(cat /sys/class/power_supply/macsmc-battery/capacity)
STATE=/run/power-alert.state
REMIND_EVERY=1800

read -r LAST_AC LAST_SENT 2>/dev/null < "$STATE" || { LAST_AC=1; LAST_SENT=0; }
NOW=$(date +%s)

if [ "$AC" = 0 ] && { [ "$LAST_AC" = 1 ] || [ $((NOW - LAST_SENT)) -ge $REMIND_EVERY ]; }; then
  send "⚠️ centralbook is on battery (${PCT}%). Plug the charger back in: at empty it shuts down and stays off until the lid is opened."
  LAST_SENT=$NOW
elif [ "$AC" = 1 ] && [ "$LAST_AC" = 0 ]; then
  send "✅ centralbook power restored, battery at ${PCT}%."
fi
echo "$AC $LAST_SENT" > "$STATE"
EOF
chmod 755 /usr/local/bin/power-alert

echo "== 3/3 systemd timer =="
cat > /etc/systemd/system/power-alert.service <<'EOF'
[Unit]
Description=Telegram alert when centralbook runs on battery
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-alert
EOF
cat > /etc/systemd/system/power-alert.timer <<'EOF'
[Unit]
Description=Check centralbook AC power every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now power-alert.timer

/usr/local/bin/power-alert test
echo "Test message sent. Timer: $(systemctl is-active power-alert.timer)"
