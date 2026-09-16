#!/usr/bin/env bash
# Laptop-side helpers for the Arc bot on the droplet.   ./deploy/remote.sh <command>
#   logs      follow the bot log            status    bot.py status
#   dash      open the dashboard            restart   restart the bot
#   push      push code/config, restart     payer TX  Relay verdict for a fill
#   notify    (re)start the Telegram notifier and show its pairing code    notifylogs  follow it
HOST="${ARC_HOST:-root@165.22.178.226}"
cd "$(dirname "$0")/.."
case "${1:-}" in
  logs)    exec ssh -t "$HOST" 'journalctl -fu arc-copybot -o cat' ;;
  dash)    exec ssh -t "$HOST" 'cd /opt/arc-copybot && .venv/bin/python dash.py' ;;
  status)  exec ssh "$HOST" 'cd /opt/arc-copybot && .venv/bin/python bot.py status' ;;
  restart) exec ssh "$HOST" 'systemctl restart arc-copybot; sleep 3; systemctl is-active arc-copybot' ;;
  push)    ./deploy/push.sh "$HOST" && ssh "$HOST" 'systemctl restart arc-copybot; sleep 3; systemctl is-active arc-copybot' ;;
  payer)   exec ssh "$HOST" "cd /opt/arc-copybot && .venv/bin/python bot.py payer ${2:?txhash}" ;;
  notify)  exec ssh -t "$HOST" 'systemctl enable --now arc-copybot-notify >/dev/null 2>&1; systemctl restart arc-copybot-notify; sleep 4; journalctl -u arc-copybot-notify -n 5 -o cat --no-pager' ;;
  notifylogs) exec ssh -t "$HOST" 'journalctl -fu arc-copybot-notify -o cat' ;;
  *) sed -n 2,6p "$0" ;;
esac
