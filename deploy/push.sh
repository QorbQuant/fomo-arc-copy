#!/usr/bin/env bash
# Run on your LAPTOP:  ./deploy/push.sh root@DROPLET_IP
# Ships arc-copybot to /opt/arc-copybot on the droplet and runs setup there.
# It only ever writes /opt/arc-copybot: the Robinhood bots on the same box live in
# /opt/rh-copybot* and are never touched from this repo.
set -euo pipefail
HOST="${1:?usage: push.sh root@IP}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=/opt/arc-copybot
if [ "$(basename "$HERE")" != "arc-copybot" ]; then
  echo "!! run this from the arc-copybot folder (got $(basename "$HERE"))"; exit 1
fi
if pgrep -f "arc-copybot/bot\.py|^python[0-9.]* bot\.py" >/dev/null; then
  echo "!! a bot is still running on this laptop. Stop it first (Ctrl+C) so two copies never trade with the same wallet."; exit 1
fi
# never ship code that cannot even be imported (the service would crash-loop)
TMP="$(mktemp -d)"; mkdir -p "$TMP/data"; cp "$HERE/wallets.json" "$HERE/solana.json" "$TMP/"
python3 -c "import json;c=json.load(open('$HERE/config.json'));c.update(live=False,router='');json.dump(c,open('$TMP/config.json','w'))"
if ! RPC_URL=https://rpc.mainnet.arc.io BOT_HOME="$TMP" python3 -c "import sys;sys.path.insert(0,'$HERE');import bot" >/dev/null 2>&1; then
  echo "!! bot.py fails to import — not pushing"; rm -rf "$TMP"; exit 1
fi
rm -rf "$TMP"
ssh "$HOST" "mkdir -p $REMOTE"
# The droplet's data/ (positions, logs) and .env (keys) are the live truth once
# deployed: NEVER overwrite them on an update. Only the very first push seeds them.
if ssh "$HOST" "test -f $REMOTE/data/state.json"; then
  EXCL=(--exclude data --exclude .env); echo "update: leaving the droplet's data/ and .env untouched"
else
  EXCL=(); echo "first deploy: seeding data/ and .env from this laptop"
fi
rsync -az --delete --exclude .venv --exclude __pycache__ --exclude .git --exclude contracts/out --exclude contracts/cache \
  ${EXCL[@]+"${EXCL[@]}"} "$HERE/" "$HOST:$REMOTE/"
ssh "$HOST" "chmod +x $REMOTE/deploy/setup.sh && $REMOTE/deploy/setup.sh"
echo
echo "next:  ssh $HOST 'systemctl restart arc-copybot && journalctl -fu arc-copybot'"
