// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {V4BackingRouter, IPoolManager, PoolKey} from "../src/V4BackingRouter.sol";
import {PrintFactory} from "../src/PrintFactory.sol";

/// Deploys Print to Robinhood Chain (4663).
///
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
contract Deploy is Script {
    // verified live on chain 4663
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    // an actively traded native-quoted V4 pool, key read off its Initialize event
    address constant ASSET = 0x28D5591A3Ce982114b90F9ccf225c97B9A81Fd3a;
    uint24 constant FEE = 2500;
    int24 constant TICK_SPACING = 25;
    address constant HOOKS = address(0);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        address me = vm.addr(pk);
        console.log("deployer ", me);
        console.log("balance  ", me.balance);
        console.log("chain    ", block.chainid);

        vm.startBroadcast(pk);

        V4BackingRouter router =
            new V4BackingRouter(PM, PoolKey(address(0), ASSET, FEE, TICK_SPACING, HOOKS));
        console.log("V4BackingRouter", address(router));

        PrintFactory factory = new PrintFactory(address(router));
        console.log("PrintFactory   ", address(factory));

        vm.stopBroadcast();

        console.log("---- verify ----");
        console.log("router.poolManager", address(router.poolManager()));
        console.log("router.asset      ", router.asset());
        console.log("factory.router    ", factory.router());
        console.log("factory.pairCount ", factory.pairCount());
    }
}
