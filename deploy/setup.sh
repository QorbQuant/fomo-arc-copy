#!/usr/bin/env bash
# Run ON the droplet as root, from /opt/arc-copybot. Own venv, own systemd unit.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d .venv ]; then
  apt-get install -y -qq python3-venv python3-pip rsync >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3-venv python3-pip rsync >/dev/null; }
  python3 -m venv .venv
  .venv/bin/pip install -q --upgrade pip
fi
if [ ! -f .venv/.requirements.sha ] || ! sha256sum -c --quiet .venv/.requirements.sha 2>/dev/null; then
  .venv/bin/pip install -q -r requirements.txt && sha256sum requirements.txt > .venv/.requirements.sha
else
  echo "requirements unchanged; skipping pip"
fi
mkdir -p data
install -m 644 deploy/arc-copybot.service /etc/systemd/system/arc-copybot.service
install -m 644 deploy/arc-copybot-notify.service /etc/systemd/system/arc-copybot-notify.service
systemctl daemon-reload
systemctl enable arc-copybot >/dev/null
# the notifier only runs once its own Telegram bot token is in .env
if grep -q "^TELEGRAM_BOT_TOKEN=." .env 2>/dev/null; then systemctl enable arc-copybot-notify >/dev/null; fi
echo "installed. start with:  systemctl start arc-copybot"
echo "logs:                   journalctl -fu arc-copybot"
