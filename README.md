# arc-copybot

Copies fomo traders' new-token buys on **Arc** (chain 5042) with USDC. One Python process,
one stateless router contract, no database. Derived from `rh-copybot` (Robinhood Chain),
with every chain assumption re-checked against Arc mainnet on its public launch day.

```
tracked wallet receives a token it held 0 of, delivered by Relay's router
        │  (ERC-20 Transfer logs, all wallets in one eth_getLogs pair)
        ▼
size = native USDC the Relay solver paid in the same tx
        ▼
gates: cash-by-address · liquidity · pool rules · holder probe · route + quote
       · Relay check (trader's own fomo buy, verified, fail-closed)
        ▼
buy `buy_usd` of USDC via CopyRouter (Uniswap V3 / hooked V4)
        ├─ +5m   sell 75%
        ├─ +10m  sell 25%
        └─ the originating wallet starts selling → sell the rest
```

**Status: paper mode.** Detection, sizing, the Relay rule, routing and the router contract are
verified on Arc mainnet (see "What has been verified"). It has not traded, and the gate
thresholds it inherited were calibrated on Robinhood Chain.

## What is different on Arc

1. **Gas is USDC, from the balance you trade with.** Native USDC (18dp, pays gas) and the
   ERC-20 at `0x3600…0000` (6dp) are one balance. The bot keeps `gas_reserve_usdc` back from
   every buy and alerts below `critical_usdc`.
2. **Cash is identified by address only.** Nine memecoins on Arc are called "USDC". A symbol
   never marks a token as cash, or as something to skip. The native-USDC system log emitter
   `0xff…fe` is also treated as cash, not as a token.
3. **Every fomo buy is a Relay fill.** A Relay solver sends native USDC to Relay's router and the
   token's last hop is router → trader. Anything else inbound is an airdrop (launch day was
   dominated by batch airdrops), so `buy_senders` accepts only the router.
4. **Plants are common**, 20% of tracked-wallet buys on launch day. The Relay check is
   mandatory and **fails closed**: no verified answer within `relay_wait_s`, no buy.
5. **Log ranges are capped** at 10,000 blocks per query even when filtered, so every lookback
   (pool keys, sale recovery, holdings) is windowed.
6. **Almost every V4 pool has a hook**, most at 1% fee with an after-swap hook that takes a
   cut of the output. The V4 quoter executes hooks, so taxes are in every quote.
7. **~2 blocks per second**, not 10. Anything expressed in blocks uses `blocks_per_second`.

## The Relay rule

`GET https://api.relay.link/requests/v2?hash=<tx>`; take the request whose `recipient` is the
trader's wallet. A buy is the trader's own only if **all** hold:

| field | required |
|---|---|
| `referrer` | `"fomo"` |
| `data.appFees` | non-empty (fomo's fees) |
| `data.inTxs[0].chainId` | `792703809` (Solana) |
| `user` (and the deposit's `depositor`, when present) | the trader's paired Solana wallet from `solana.json` |

`referrer`, `user` and `depositor` are each written by whoever requests the quote; only a
Solana-origin deposit must be signed by its depositor, which is why the origin chain matters.
A trader with no paired wallet on file is **unverifiable** and skipped. `astaso1` is the one
such trader today. `python bot.py payer <txhash>` prints the record and the verdict.

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env          # PRIVATE_KEY of a fresh hot wallet, RPC_URL of a dedicated endpoint
python bot.py                 # paper mode: config.json ships with "live": false
```

- **RPC.** Use this bot's own endpoint, never the scanner's. Alchemy serves Arc mainnet as
  `https://arc-mainnet.g.alchemy.com/v2/<KEY>` once Arc is enabled on the app. Measured from
  the droplet: no 10-block log cap (10,000-block ranges answer, 20,000 results max), ~15 ms
  calls, 40-call batches with no refusals, working WSS and `eth_simulateV1`. The config is
  tuned for it (0.5 s polls). On the public node (`https://rpc.mainnet.arc.io`) use
  `poll_seconds` 2 and `holder_probe_wait_s` 3.
- **Wallets.** `wallets.json` holds the 147 traders from the scanner's `traders.json`;
  `solana.json` maps each to its paired Solana wallet (146 of 147).
- **Every batched RPC item that comes back refused for rate limiting is resent on its own.**
  A refusal is never read as "no result" (the scanner once lost 425 fills that way).

## Tools

| command | what it does |
|---|---|
| `python bot.py` | the bot (paper unless `live: true`) |
| `python bot.py status` | open/closed positions and PnL |
| `python bot.py route <token>` | route, quotes, price impact and the holder-probe verdict |
| `python bot.py payer <txhash> [wallet]` | Relay's record for a fill and the verdict |
| `python bot.py wallet` | hot wallet address, USDC balance and router |
| `python bot.py deploy-router` | deploy CopyRouter from the hot wallet and verify its code and wiring |
| `python bot.py holdings <wallet>` | what a wallet holds |
| `python bot.py sell <symbol> [pct]` / `adopt <token> <usd>` | manual exit / take over an orphaned bag |
| `python tools/simulate_router.py <token> …` | runs CopyRouter buys and sells against real Arc state with nothing deployed (see below) |
| `python dash.py` | terminal dashboard |
| `python notify.py` | Telegram relay (separate process; `BOT_UNIT` names the systemd unit) |

## Arc addresses

From Uniswap's official list (`github.com/Uniswap/contracts`, `deployments/json/5042.json`),
each confirmed with `eth_getCode` and cross-wired on-chain.

| contract | address |
|---|---|
| V4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` (byte-identical to Robinhood's) |
| V4Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` (byte-identical to Robinhood's) |
| V4 PositionManager | `0x6049c9a0e26405c0985f9e3685c87d0ae917f82b` |
| V3 Factory | `0xf0db7b58379503491d857db50ac9ece64c653918` |
| QuoterV2 | `0x7dfd4f31be6814d2906bde155c3e1b146eac1468` |
| SwapRouter02 | `0x53bf6b0684ec7ef91e1387da3d1a1769bc5a6f77` |
| Relay router | `0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f` |
| USDC (ERC-20 view) | `0x3600000000000000000000000000000000000000` |

The addresses Robinhood Chain uses for V3 Factory and QuoterV2 hold unrelated contracts on Arc.

## Arc-specific config

| key | value | meaning |
|---|---|---|
| `buy_senders` | [Relay router] | a token counts as bought only when it arrives from one of these |
| `relay_gate` / `relay_wait_s` / `relay_unknown` | true / 5 / skip | require a verified fomo buy; wait this long; no answer means no buy |
| `gas_reserve_usdc` / `critical_usdc` | 3 / 1 | kept back from every buy for exit gas; alert below |
| `blocks_per_second` | 1.98 | Arc's block rate |
| `dexscreener_chain` | arc | dexscreener's chain slug |
| `log_window_blocks` | 5000 | window for any log lookback |
| `holder_probe_lookback_blocks` | 1200 | ~10 minutes of recent holders |
| `plant_gate` | false | must stay off: every genuine Arc buy carries native USDC as value |
| `min_pool_age_minutes` | 0 | on launch day a 2-minute floor filtered nothing and plants sat at 5–30 minutes |

The remaining gates (fake LP, sell ratios, quarantine, honeypot ratio, write-offs, exits) keep
rh-copybot's values, which were measured on Robinhood Chain. Re-check them against this bot's
`data/signals.jsonl` after a week of Arc data.

## What has been verified

- **Detection and sizing.** 16 launch-day buys by four leaders were dissected. All arrived
  router → trader, all were paid by a Relay solver's native USDC transfer to the router, and
  that payment is what the bot records as the leader's size.
- **The Relay rule.** 15 of those 16 pass all four conditions; the 16th, frankdegods' DOLLAR
  buy, is `referrer "relay.link"` paid by `EA8y4pJJ…` and comes back planted, matching the
  scanner's campaign list.
- **Routing.** Hooked V4 pools (two different hook contracts), a direct V3 pool, and a V3
  route through an intermediate token all resolve and quote both ways.
- **The router contract.** `tools/simulate_router.py` runs `CopyRouter.swap` for a buy and
  for selling the output back on the real Arc state, using `eth_call` with state overrides
  (runtime code from the node, native balance and storage overrides). On all four route types
  above, buy and sell outputs equal the quoters exactly and an impossible `minOut` reverts.
  `forge test` cannot do this: USDC calls Arc's blocklist precompile, which Foundry lacks.
- **The watcher.** A 15-minute paper run on the public node stayed 1–2 blocks behind head,
  recovered from every rate-limit refusal, correctly ignored airdrops, and skipped one add to
  an existing bag. Traders were quiet in that window, so it did not see a fresh buy live;
  replays of real buys through the full path did buy (paper) the genuine ones.

## Going live

1. Enable Arc mainnet on a dedicated Alchemy app and put its URL in `.env`.
2. Paper-trade for a day and compare the bot's would-be buys with circletrenches.com's labels.
3. Fund the hot wallet with USDC (gas included) and save its key into the droplet's `.env`,
   then run `python bot.py deploy-router` there (no Foundry needed: the creation bytecode is
   committed in `contracts/CopyRouter.creation.hex`, built from `contracts/src/CopyRouter.sol`
   with solc 0.8.36). Put the printed address into `config.json` → `router`. `./deploy.sh`
   does the same from a laptop with Foundry.
4. `python tools/simulate_router.py` on a few current tokens once more, then `"live": true`.

## Running on the droplet

`./deploy/push.sh root@IP` ships the repo to **`/opt/arc-copybot`** only, with its own venv
and a single `arc-copybot` systemd unit capped at 300MB. It refuses to run from any folder
not named `arc-copybot`, and never writes the Robinhood bots in `/opt/rh-copybot*`. As
there, the droplet's `data/` and `.env` are seeded once and never overwritten afterwards.
`./deploy/remote.sh logs | status | dash | restart | push | payer TX`.

## Not done yet

- dexscreener is still the source of price, liquidity and pool lists; brand-new pools it has
  not indexed are skipped ("no dexscreener price"). On-chain pool discovery would fix that.
- No websocket feed on Arc yet (Alchemy's Arc WSS is untested).
- `stats.py` and `backtest.py` were left behind: they are Robinhood-specific and there is no
  Arc trade history to analyze yet.
- Honeypots and sell taxes on Arc have not been measured beyond what the hooks show in quotes.

## Caveats

- You always fill *after* the trader you copy, and on Arc the Relay check adds its own wait.
- The hot wallet key in `.env` controls the funds. Use a throwaway wallet.
- Unaudited prototype. Paper-trade it before it touches money.
