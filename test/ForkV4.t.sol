// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {V4BackingRouter, IPoolManager, PoolKey} from "../src/V4BackingRouter.sol";
import {PrintFactory} from "../src/PrintFactory.sol";
import {PrintCoin} from "../src/PrintCoin.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// Runs against Robinhood Chain itself. Nothing here is a mock: the PoolManager, the
/// pool and the asset are the live ones.
///
///   forge test --match-contract ForkV4 --fork-url robinhood -vv
contract ForkV4Test is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    // a live, ACTIVELY TRADED native-quoted pool (98 swaps in 800 blocks),
    // key read off its Initialize event on chain
    address constant ASSET = 0x28D5591A3Ce982114b90F9ccf225c97B9A81Fd3a;
    uint24 constant FEE = 2500;
    int24 constant TICK_SPACING = 25;
    address constant HOOKS = address(0);

    address alice = address(0xA11CE);

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), ASSET, FEE, TICK_SPACING, HOOKS);
    }

    function test_ChainIsReal() public view {
        assertEq(block.chainid, 4663, "not Robinhood Chain");
        assertGt(address(PM).code.length, 0, "PoolManager has no code");
        assertGt(ASSET.code.length, 0, "asset has no code");
        console.log("block   ", block.number);
        console.log("PM code ", address(PM).code.length);
    }

    /// The whole point: a Print coin, on the real chain, turning a real fee into a real
    /// balance of a real asset held in the vault.
    function test_LiveSwapFillsTheVault() public {
        V4BackingRouter router = new V4BackingRouter(PM, _key());
        PrintFactory factory = new PrintFactory(address(router));
        PrintCoin coin = PrintCoin(payable(factory.launch("Fork Test", "FORK", ASSET)));

        assertEq(coin.wrapped(), address(0), "native pool: wrapped is address(0)");
        assertTrue(coin.routerReady(), "router must be recognised despite wrapped==0");

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        coin.buy{value: 10 ether}(0);

        console.log("coins to buyer  ", coin.balanceOf(alice));
        console.log("vault balance   ", coin.vault().balance());
        console.log("pending fees    ", coin.pendingFees());
        console.log("backing / coin  ", coin.backingPerToken());

        assertGt(coin.balanceOf(alice), 0, "buyer got no coins");
        assertGt(
            coin.vault().balance(),
            0,
            "THE FEE DID NOT REACH THE VAULT - the swap route is wrong"
        );
        assertEq(coin.pendingFees(), 0, "fee should not be queued if the swap worked");
        assertEq(
            IERC20(ASSET).balanceOf(address(coin.vault())),
            coin.vault().balance(),
            "vault must hold the real asset"
        );
    }

    /// And a holder can take the real asset out again.
    function test_LiveRedeemReturnsRealAsset() public {
        V4BackingRouter router = new V4BackingRouter(PM, _key());
        PrintFactory factory = new PrintFactory(address(router));
        PrintCoin coin = PrintCoin(payable(factory.launch("Fork Test", "FORK", ASSET)));

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        coin.buy{value: 20 ether}(0);
        vm.assume(coin.vault().balance() > 0);

        uint256 held = coin.balanceOf(alice);
        uint256 expected = coin.redeemableFor(held);

        vm.prank(alice);
        uint256 got = coin.redeem(held);

        console.log("redeemed asset  ", got);
        assertEq(got, expected);
        assertEq(IERC20(ASSET).balanceOf(alice), got, "real asset must land in the wallet");
        assertGt(got, 0);
    }

    /// No try/catch anywhere: surfaces the real revert from V4.
    function test_Diagnose_RawSwap() public {
        V4BackingRouter r = new V4BackingRouter(PM, _key());
        console.log("sqrtPriceX96    ", uint256(r.sqrtPriceX96()));

        address[] memory path = new address[](2);
        path[0] = address(0);
        path[1] = ASSET;
        uint256[] memory q = r.getAmountsOut(1 ether, path);
        console.log("quote for 1e18  ", q[1]);

        vm.deal(address(this), 10 ether);
        uint256[] memory got = r.swapExactETHForTokens{value: 1 ether}(0, path, address(this), block.timestamp);
        console.log("swapped out     ", got[1]);
        assertGt(got[1], 0);
    }

    receive() external payable {}

    /// How far is spot from the real fill at the sizes PrintCoin actually swaps?
    function test_Diagnose_SlippageBySize() public {
        address[] memory path = new address[](2);
        path[0] = address(0); path[1] = ASSET;
        vm.deal(address(this), 100 ether);

        uint256[5] memory sizes =
            [uint256(0.001 ether), 0.01 ether, 0.1 ether, 0.5 ether, 1 ether];
        for (uint256 i = 0; i < sizes.length; i++) {
            V4BackingRouter r = new V4BackingRouter(PM, _key());   // fresh pool state each time
            uint256 q = r.getAmountsOut(sizes[i], path)[1];
            uint256 got = r.swapExactETHForTokens{value: sizes[i]}(0, path, address(this), block.timestamp)[1];
            uint256 pct = q == 0 ? 0 : (got * 10000) / q;
            console.log("size(wei)", sizes[i]);
            console.log("   fill as bps of spot quote:", pct);
        }
    }


}
