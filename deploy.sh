#!/usr/bin/env bash
# Deploys CopyRouter to Arc mainnet from the PRIVATE_KEY in .env, then paste the
# printed address into config.json "router". Constructor: Uniswap's official Arc
# SwapRouter02 and the V4 PoolManager (github.com/Uniswap/contracts deployments/json/5042.json).
# Gas on Arc is paid in USDC, so the wallet needs a few USDC before this runs.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
RPC="${RPC_URL:-https://rpc.mainnet.arc.io}"
forge create --root contracts src/CopyRouter.sol:CopyRouter \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args 0x53bf6b0684ec7ef91e1387da3d1a1769bc5a6f77 0x8366a39CC670B4001A1121B8F6A443A643e40951
