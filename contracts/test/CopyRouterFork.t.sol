// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CopyRouter, IERC20, ISwapRouter02, IPoolManager} from "../src/CopyRouter.sol";

interface Vm {
    function deal(address, uint256) external;
}

/// forge test --root contracts --fork-url https://rpc.mainnet.arc.io
///
/// Only what Foundry can check on an Arc fork lives here. USDC's transfer path calls Arc's
/// native blocklist precompile (0x1800..0001), which Foundry's EVM does not implement, so
/// every swap reverts with OpcodeNotFound on a fork. Swaps are verified against the real
/// node instead:  python tools/simulate_router.py <token> ...
contract CopyRouterForkTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant TRADER = address(0xA11CE);
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant SWAP_ROUTER = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function testDeploysWithArcAddresses() public {
        CopyRouter router = new CopyRouter(ISwapRouter02(SWAP_ROUTER), IPoolManager(POOL_MANAGER));
        require(address(router.swapRouter()) == SWAP_ROUTER && address(router.poolManager()) == POOL_MANAGER, "wiring");
    }

    function testNativeAndErc20UsdcAreOneBalance() public {
        vm.deal(TRADER, 1_000 ether); // 1,000 USDC on the 18dp native view
        require(IERC20(USDC).balanceOf(TRADER) == 1_000e6, "ERC-20 view does not follow the native balance");
    }
}
