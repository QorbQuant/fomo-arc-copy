#!/usr/bin/env python3
"""Simulate CopyRouter buys and sells on Arc's real state, with nothing deployed or sent.

  python tools/simulate_router.py <token> [<token> ...] [--fresh]
  (uses config.json's deployed router; --fresh or no router simulates a new build instead)

Why not `forge test`: USDC on Arc checks a native blocklist precompile (0x1800..0001) on
every transfer, which Foundry's EVM does not implement, so no local fork can move USDC.
The Arc node does, so this uses plain eth_call with state overrides instead:
  - the router's runtime code comes from running its constructor on the node (immutables filled)
  - the test account gets native USDC through a balance override (the ERC-20 view follows it)
  - allowances and token balances are written into storage; their mapping slots are found
    by probing with overrides
For each token it takes the route the bot itself would pick, runs router.swap for a buy and
for selling that output back, and compares both with the quoters. A mismatch or revert
means do not go live on that route.
"""
import json, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bot  # noqa: E402
from eth_abi import encode  # noqa: E402
from eth_utils import keccak  # noqa: E402

TRADER = "0x00000000000000000000000000000000000a11ce"
ROUTER = "0x000000000000000000000000000000000c0b7e11"
ART = HERE / "contracts/out/CopyRouter.sol/CopyRouter.json"


def post(method, params):
    for i in range(8):
        r = bot._s.post(bot.RPC_URL, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=60).json()
        if "error" in r and bot._rate_limited(r["error"]):
            time.sleep(1.5 + i)
            continue
        return r
    return r


def mapping_key(owner, slot, spender=None):
    inner = keccak(bytes.fromhex(owner[2:].rjust(64, "0")) + slot.to_bytes(32, "big"))
    return "0x" + (keccak(bytes.fromhex(spender[2:].rjust(64, "0")) + inner) if spender else inner).hex()


def probe_slot(token, fn):
    """First storage slot whose override changes the view `fn` reads."""
    for slot in list(range(0, 16)) + [51, 52, 53, 101, 102, 103, 151, 152, 153, 201, 202, 203]:
        key, data = fn(slot)
        r = post("eth_call", [{"to": token, "data": data}, "latest", {token: {"stateDiff": {key: "0x" + (777).to_bytes(32, "big").hex()}}}])
        if r.get("result") and int(r["result"], 16) == 777:
            return slot
    return None


def main(tokens):
    tokens = [t for t in tokens if not t.startswith("--")]
    if not ART.exists() and not bot.ROUTER:
        sys.exit("build the router first:  forge build --root contracts")
    global ROUTER
    code = None
    if bot.ROUTER and "--fresh" not in sys.argv:
        ROUTER = bot.ROUTER.lower()  # the deployed router itself: no code override
        print(f"simulating against the deployed router {bot.ROUTER}")
    else:
        art = json.loads(ART.read_text())
        ctor = art["bytecode"]["object"] + encode(["address", "address"], [bot.SWAP_ROUTER02, bot.POOL_MANAGER]).hex()
        code = post("eth_call", [{"from": TRADER, "data": ctor}, "latest"]).get("result")
        if not code or len(code) < 100:
            sys.exit("could not obtain the router runtime code from the node")
        print("simulating a freshly built router (code override)")
    sel = lambda s: keccak(text=s)[:4]
    usdc_allow = probe_slot(bot.USDC, lambda s: (mapping_key(TRADER, s, ROUTER),
                                                 "0x" + (sel("allowance(address,address)") + encode(["address", "address"], [TRADER, ROUTER])).hex()))
    if usdc_allow is None:
        sys.exit("could not locate USDC's allowance slot")
    amount_in = int(bot.CFG["buy_usd"] * 10**bot.USDC_DEC)
    ok_all = True
    for token in tokens:
        token = token.lower()
        meta = bot.token_meta(token)
        try:
            legs_buy, legs_sell, desc, _depth = bot.discover_route(token)
        except Exception as e:
            print(f"{meta['symbol']:<12} no route: {e}")
            ok_all = False
            continue
        swap = lambda legs, amt, mn: "0x" + (sel(f"swap({bot.LEG_T}[],uint256,uint256,address)") + encode(
            [f"{bot.LEG_T}[]", "uint256", "uint256", "address"], [[bot.leg_tuple(l) for l in legs], amt, mn, TRADER])).hex()
        ov = {TRADER: {"balance": hex(10_000 * 10**18)}, **({ROUTER: {"code": code}} if code else {}),
              bot.USDC: {"stateDiff": {mapping_key(TRADER, usdc_allow, ROUTER): "0x" + "f" * 64}}}
        q_buy = bot.quote_route(legs_buy, amount_in)
        r = post("eth_call", [{"from": TRADER, "to": ROUTER, "data": swap(legs_buy, amount_in, 1)}, "latest", ov])
        if not r.get("result"):
            print(f"{meta['symbol']:<12} BUY REVERTS via {desc}: {json.dumps(r.get('error'))[:160]}")
            ok_all = False
            continue
        got = int(r["result"], 16)
        bal_slot = probe_slot(token, lambda s: (mapping_key(TRADER, s), "0x" + (sel("balanceOf(address)") + encode(["address"], [TRADER])).hex()))
        alw_slot = probe_slot(token, lambda s: (mapping_key(TRADER, s, ROUTER),
                                               "0x" + (sel("allowance(address,address)") + encode(["address", "address"], [TRADER, ROUTER])).hex()))
        line = f"{meta['symbol']:<12} {desc:<40} buy ${bot.CFG['buy_usd']:.0f} -> {got / 10**meta['decimals']:,.6g} (quoter {'match' if got == q_buy else 'MISMATCH'})"
        if got != q_buy:
            ok_all = False
        if bal_slot is None or alw_slot is None:
            print(line + "  | sell not simulated: token storage layout is non-standard")
            continue
        ov[token] = {"stateDiff": {mapping_key(TRADER, bal_slot): "0x" + got.to_bytes(32, "big").hex(),
                                   mapping_key(TRADER, alw_slot, ROUTER): "0x" + "f" * 64}}
        q_sell = bot.quote_route(legs_sell, got)
        r = post("eth_call", [{"from": TRADER, "to": ROUTER, "data": swap(legs_sell, got, 1)}, "latest", ov])
        if not r.get("result"):
            print(line + f"  | SELL REVERTS: {json.dumps(r.get('error'))[:120]}")
            ok_all = False
            continue
        back = int(r["result"], 16)
        if back != q_sell:
            ok_all = False
        print(line + f"  | sell back -> ${back / 1e6:.2f} (quoter {'match' if back == q_sell else 'MISMATCH'}, round trip {back / amount_in - 1:+.1%})")
    return 0 if ok_all else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1:]))
