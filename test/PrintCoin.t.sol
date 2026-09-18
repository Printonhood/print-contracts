// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PrintFactory} from "../src/PrintFactory.sol";
import {PrintCoin} from "../src/PrintCoin.sol";
import {PrintVault} from "../src/PrintVault.sol";
import {MockERC20, MockRouter} from "./mocks/Mocks.sol";

contract PrintCoinTest is Test {
    PrintFactory factory;
    MockERC20 nvda;
    MockRouter router;
    PrintCoin coin;
    PrintVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC01);

    function setUp() public {
        nvda = new MockERC20("Nvidia xStock", "NVDAx");
        router = new MockRouter(nvda, 1_000 ether, 1_000_000 ether);
        factory = new PrintFactory(address(router));

        address c = factory.launch("Tendie Machine", "TENDIE", address(nvda));
        coin = PrintCoin(payable(c));
        vault = coin.vault();

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ------------------------------------------------------------ launchpad

    function test_LaunchRegistersPair() public view {
        assertEq(factory.pairCount(), 1);
        (address c,, address backing,,) = factory.pairs(0);
        assertEq(c, address(coin));
        assertEq(backing, address(nvda));
        assertEq(coin.symbol(), "TENDIE");
        assertEq(coin.totalSupply(), factory.DEFAULT_SUPPLY());
    }

    function test_AnyoneCanLaunch() public {
        vm.prank(carol);
        address c2 = factory.launch("Goldie", "GOLDIE", address(nvda));
        assertEq(factory.pairCount(), 2);
        (,,, address creator,) = factory.pairs(1);
        assertEq(creator, carol);
        assertTrue(c2 != address(coin));
    }

    // ------------------------------------------------------------ the fee really buys stock

    function test_BuyMovesFeeIntoVaultAsRealAsset() public {
        assertEq(vault.balance(), 0);
        vm.prank(alice);
        coin.buy{value: 10 ether}(0);

        assertGt(vault.balance(), 0, "vault must hold real NVDAx");
        assertEq(nvda.balanceOf(address(vault)), vault.balance());
        assertGt(coin.balanceOf(alice), 0);
        // supply is fixed - the buy moved inventory, it did not mint
        assertEq(coin.totalSupply(), factory.DEFAULT_SUPPLY());
    }

    function test_SellAlsoBuysBacking() public {
        vm.prank(alice);
        coin.buy{value: 10 ether}(0);
        uint256 afterBuy = vault.balance();

        uint256 held = coin.balanceOf(alice);
        vm.prank(alice);
        coin.sell(held / 2, 0);

        assertGt(vault.balance(), afterBuy, "selling must also buy the floor");
    }

    // ------------------------------------------------------------ THE INVARIANT

    function test_BackingPerTokenNeverFalls_MixedActivity() public {
        uint256 last = coin.backingPerToken();

        for (uint256 i = 0; i < 12; i++) {
            vm.prank(alice);
            coin.buy{value: 3 ether}(0);
            assertGe(coin.backingPerToken(), last, "fell after buy");
            last = coin.backingPerToken();

            vm.prank(bob);
            coin.buy{value: 1 ether}(0);
            assertGe(coin.backingPerToken(), last, "fell after buy");
            last = coin.backingPerToken();

            uint256 held = coin.balanceOf(alice);
            if (held > 0) {
                uint256 third = held / 3;
                vm.prank(alice);
                coin.sell(third, 0);
                assertGe(coin.backingPerToken(), last, "fell after sell");
                last = coin.backingPerToken();
            }
        }
        assertGt(last, 0);
    }

    function testFuzz_BackingPerTokenNeverFalls(uint96[8] calldata buys, uint8 sellPct) public {
        sellPct = uint8(bound(sellPct, 1, 99));
        uint256 last = coin.backingPerToken();
        vm.deal(alice, 100_000 ether);

        for (uint256 i = 0; i < buys.length; i++) {
            uint256 amt = bound(uint256(buys[i]), 0.001 ether, 500 ether);
            vm.prank(alice);
            try coin.buy{value: amt}(0) {} catch {}
            assertGe(coin.backingPerToken(), last, "fell after buy");
            last = coin.backingPerToken();

            uint256 held = coin.balanceOf(alice);
            if (held > 1000) {
                vm.prank(alice);
                try coin.sell((held * sellPct) / 100, 0) {} catch {}
                assertGe(coin.backingPerToken(), last, "fell after sell");
                last = coin.backingPerToken();
            }
        }
    }

    // ------------------------------------------------------------ redemption

    function test_RedeemPaysProportionalShare() public {
        vm.prank(alice);
        coin.buy{value: 50 ether}(0);
        vm.prank(bob);
        coin.buy{value: 50 ether}(0);

        uint256 vaultBefore = vault.balance();
        uint256 supplyBefore = coin.totalSupply();
        uint256 aliceCoins = coin.balanceOf(alice);
        uint256 expected = (vaultBefore * aliceCoins) / supplyBefore;

        vm.prank(alice);
        uint256 got = coin.redeem(aliceCoins);

        assertEq(got, expected, "payout must be exactly pro-rata");
        assertEq(nvda.balanceOf(alice), expected, "real asset must land in the wallet");
        assertEq(coin.balanceOf(alice), 0);
        assertEq(coin.totalSupply(), supplyBefore - aliceCoins, "coins must be burned");
    }

    function test_RedeemLeavesEveryoneElsesBackingUnchanged() public {
        vm.prank(alice);
        coin.buy{value: 40 ether}(0);
        vm.prank(bob);
        coin.buy{value: 40 ether}(0);

        uint256 before = coin.backingPerToken();
        uint256 aliceCoins = coin.balanceOf(alice);
        vm.prank(alice);
        coin.redeem(aliceCoins);
        uint256 afterRedeem = coin.backingPerToken();

        // exactly flat, allowing only integer-division dust
        assertApproxEqAbs(afterRedeem, before, 2, "redeem must not dilute holders");
        assertGe(afterRedeem, before - 2);
    }

    function test_RedeemIsTheOnlyWayOut() public {
        vm.prank(alice);
        coin.buy{value: 20 ether}(0);
        assertGt(vault.balance(), 0);

        // nobody but the coin can move the vault
        vm.prank(alice);
        vm.expectRevert(PrintVault.OnlyCoin.selector);
        vault.payout(alice, 1);

        vm.prank(address(this)); // the deployer has no power either
        vm.expectRevert(PrintVault.OnlyCoin.selector);
        vault.payout(address(this), 1);
    }

    // ------------------------------------------------------------ "what if everyone sells"

    function test_EveryoneSells_VaultSurvivesAndStillRedeems() public {
        vm.prank(alice);
        coin.buy{value: 100 ether}(0);
        vm.prank(bob);
        coin.buy{value: 100 ether}(0);
        vm.prank(carol);
        coin.buy{value: 100 ether}(0);

        uint256 vaultAtPeak = vault.balance();

        // a full-blown exit: everyone dumps everything
        uint256 aliceAll = coin.balanceOf(alice);
        uint256 bobAll = coin.balanceOf(bob);
        vm.prank(alice);
        coin.sell(aliceAll, 0);
        vm.prank(bob);
        coin.sell(bobAll, 0);

        assertGt(vault.balance(), vaultAtPeak, "the panic itself bought more backing");

        // carol, still holding, can take her stock out
        uint256 carolCoins = coin.balanceOf(carol);
        uint256 expected = (vault.balance() * carolCoins) / coin.totalSupply();
        vm.prank(carol);
        uint256 got = coin.redeem(carolCoins);
        assertEq(got, expected);
        assertGt(got, 0, "a holder must still get real stock after a full dump");
    }

    function test_PriceCanFallButBackingCannot() public {
        vm.prank(alice);
        coin.buy{value: 100 ether}(0);

        (uint256 priceBefore,) = coin.quoteSell(1 ether);
        uint256 backingBefore = coin.backingPerToken();

        uint256 half = coin.balanceOf(alice) / 2;
        vm.prank(alice);
        coin.sell(half, 0);

        (uint256 priceAfter,) = coin.quoteSell(1 ether);
        assertLt(priceAfter, priceBefore, "price should fall on a dump");
        assertGe(coin.backingPerToken(), backingBefore, "backing must not");
    }

    // ------------------------------------------------------------ resilience

    function test_ThinLiquidityDoesNotBrickTrading() public {
        router.setBroken(true);

        vm.prank(alice);
        coin.buy{value: 10 ether}(0); // must not revert
        assertGt(coin.balanceOf(alice), 0, "trading continues when the DEX is down");
        assertGt(coin.pendingFees(), 0, "fee is held, not lost");
        assertEq(vault.balance(), 0);

        router.setBroken(false);
        coin.sweepFees();
        assertEq(coin.pendingFees(), 0);
        assertGt(vault.balance(), 0, "held fees reach the vault once the pool is back");
    }

    function test_NoMintFunctionExists() public {
        uint256 s = coin.totalSupply();
        vm.prank(alice);
        coin.buy{value: 100 ether}(0);
        assertEq(coin.totalSupply(), s, "supply must be fixed");
    }

    function test_CannotSellMoreThanHeld() public {
        vm.prank(alice);
        coin.buy{value: 10 ether}(0);
        uint256 tooMuch = coin.balanceOf(alice) + 1;
        vm.prank(alice);
        vm.expectRevert(PrintCoin.InsufficientBalance.selector);
        coin.sell(tooMuch, 0);
    }

    function test_SlippageGuardsHold() public {
        vm.prank(alice);
        vm.expectRevert(PrintCoin.InsufficientOutput.selector);
        coin.buy{value: 1 ether}(type(uint128).max);
    }

    // ------------------------------------------------------------ board wiring

    function test_BoardRowReadsEverythingTheSiteNeeds() public {
        vm.prank(alice);
        coin.buy{value: 25 ether}(0);

        (
            address c,
            address backing,
            ,
            ,
            string memory nm,
            string memory sym,
            uint256 supply,
            uint256 vaultBal,
            uint256 bpt,
            ,
        ) = factory.boardRow(0);

        assertEq(c, address(coin));
        assertEq(backing, address(nvda));
        assertEq(nm, "Tendie Machine");
        assertEq(sym, "TENDIE");
        assertEq(supply, factory.DEFAULT_SUPPLY());
        assertGt(vaultBal, 0);
        assertGt(bpt, 0);
    }

    // ------------------------------------------------------------ no router at all

    function test_LaunchingWithNoRouterStillTrades() public {
        // a factory pointed at an address with no code at all
        PrintFactory f2 = new PrintFactory(address(0xDEAD));
        PrintCoin c2 = PrintCoin(payable(f2.launch("Orphan", "ORPH", address(nvda))));

        assertEq(c2.wrapped(), address(0), "router probe must fail softly");

        vm.prank(alice);
        c2.buy{value: 5 ether}(0);           // must NOT revert
        assertGt(c2.balanceOf(alice), 0, "trading works with no DEX in existence");
        assertGt(c2.pendingFees(), 0, "fees queue safely");

        uint256 held = c2.balanceOf(alice);
        vm.prank(alice);
        c2.sell(held / 2, 0);                // selling must not revert either
        assertGt(c2.pendingFees(), 0);
    }
}
