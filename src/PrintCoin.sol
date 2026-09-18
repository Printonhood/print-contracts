// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBackingRouter} from "./interfaces/IBackingRouter.sol";
import {PrintVault} from "./PrintVault.sol";

/// @title PrintCoin
/// @notice A coin whose market lives in the contract itself and whose floor is a real
///         balance of a real asset.
///
/// Three moving parts:
///   1. A constant-product market priced in native USDG. Buying and selling both happen
///      here, so the coin does not depend on a DEX pool existing for it.
///   2. A fee on every buy AND every sell, which is immediately spent buying the paired
///      asset and sent to a vault that has no withdraw function.
///   3. `redeem` — burn coins, take that fraction of the vault.
///
/// THE INVARIANT, enforced in `_backingPerToken` and asserted in the tests:
///   backing-per-coin (vault balance / totalSupply) NEVER DECREASES.
///   - totalSupply is fixed at construction. Buying and selling move coins between the
///     holder and this contract; they never mint.
///   - Fees only ever add to the vault, so the ratio rises.
///   - `redeem` pays out exactly amount * vault / supply and burns exactly amount, which
///     leaves the ratio algebraically unchanged.
contract PrintCoin {
    // ---------------------------------------------------------------- ERC20
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------- market
    /// @notice Virtual native reserve — sets the opening price, never withdrawable.
    uint256 public immutable virtualNative;
    /// @notice Live curve reserves. `nativeReserve - virtualNative` is the real USDG held.
    uint256 public nativeReserve;
    uint256 public tokenReserve;

    /// @notice Fee on both sides, in basis points.
    uint16 public immutable feeBps;
    /// @notice Max slippage tolerated when the fee buys the backing asset, in bps.
    /// @dev Measured on a live Robinhood Chain V4 pool, fill as a share of the spot quote:
    ///        0.001 USDG 99.67% | 0.01 99.32% | 0.1 95.95% | 0.5 83.92% | 1.0 75.73%
    ///      A spot quote ignores both the pool fee and price impact, so a tight band just
    ///      means fees queue forever and never reach the vault. Too loose only means a
    ///      slightly worse fill on an amount that is always small — and the vault can
    ///      only ever gain. Hence a wide default, set per coin at launch.
    uint16 public immutable maxSlippageBps;

    // ---------------------------------------------------------------- backing
    PrintVault public immutable vault;
    IERC20 public immutable backing;
    IBackingRouter public immutable router;
    /// @notice Wrapped-native address the swap path starts with, read once at construction.
    /// @dev address(0) is a LEGITIMATE value: on Uniswap V4 native USDG is currency0, so the
    ///      V4 adapter reports address(0). Never use it as a "no router" sentinel — that is
    ///      what `routerReady` is for. Conflating the two silently skipped every swap.
    address public wrapped;
    /// @notice Whether the router answered the probe at all.
    bool public routerReady;
    /// @notice Fees that could not be swapped yet (no liquidity / bad price). Retried on
    ///         the next trade or by anyone calling `sweepFees`. Never withdrawable.
    uint256 public pendingFees;

    event Bought(address indexed buyer, uint256 nativeIn, uint256 tokensOut, uint256 fee);
    event Sold(address indexed seller, uint256 tokensIn, uint256 nativeOut, uint256 fee);
    event Redeemed(address indexed holder, uint256 tokensBurned, uint256 backingOut);
    event BackingBought(uint256 nativeSpent, uint256 assetReceived);
    event BackingBuyFailed(uint256 nativeHeld);

    error ZeroAmount();
    error InsufficientOutput();
    error InsufficientBalance();
    error NativeTransferFailed();
    error SupplyExhausted();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint256 virtualNative_,
        uint16 feeBps_,
        address backing_,
        address router_,
        uint16 maxSlippageBps_
    ) {
        require(totalSupply_ > 0 && virtualNative_ > 0, "bad params");
        require(feeBps_ <= 1000, "fee > 10%");
        require(maxSlippageBps_ <= 5000, "slippage > 50%");
        maxSlippageBps = maxSlippageBps_;

        name = name_;
        symbol = symbol_;
        feeBps = feeBps_;

        // Entire supply is minted once, to this contract, as curve inventory.
        // Nothing can ever mint again — there is no mint function.
        totalSupply = totalSupply_;
        balanceOf[address(this)] = totalSupply_;
        emit Transfer(address(0), address(this), totalSupply_);

        virtualNative = virtualNative_;
        nativeReserve = virtualNative_;
        tokenReserve = totalSupply_;

        backing = IERC20(backing_);
        router = IBackingRouter(router_);
        vault = new PrintVault(address(this), backing_);

        // Never let a missing router brick trading: probe it, do not trust it.
        // A high-level call would revert on the compiler's extcodesize check BEFORE the
        // call, and that revert is not catchable — so probe with a raw staticcall.
        (wrapped, routerReady) = _probeWrapped(router_);
    }

    // ---------------------------------------------------------------- views

    /// @notice Backing held per coin, scaled by 1e18. This number never goes down.
    function backingPerToken() public view returns (uint256) {
        uint256 s = totalSupply;
        if (s == 0) return 0;
        return (vault.balance() * 1e18) / s;
    }

    /// @notice What `amount` coins would redeem for right now.
    function redeemableFor(uint256 amount) public view returns (uint256) {
        uint256 s = totalSupply;
        if (s == 0) return 0;
        return (vault.balance() * amount) / s;
    }

    /// @notice Coins out for a given native spend, fee included.
    function quoteBuy(uint256 nativeIn) public view returns (uint256 tokensOut, uint256 fee) {
        fee = (nativeIn * feeBps) / 10_000;
        uint256 net = nativeIn - fee;
        tokensOut = (tokenReserve * net) / (nativeReserve + net);
    }

    /// @notice Native out for a given number of coins, fee deducted.
    function quoteSell(uint256 tokensIn) public view returns (uint256 nativeOut, uint256 fee) {
        uint256 gross = (nativeReserve * tokensIn) / (tokenReserve + tokensIn);
        fee = (gross * feeBps) / 10_000;
        nativeOut = gross - fee;
    }

    // ---------------------------------------------------------------- trading

    /// @notice Buy coins off the curve with native USDG.
    function buy(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee;
        (tokensOut, fee) = quoteBuy(msg.value);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert InsufficientOutput();
        if (tokensOut > tokenReserve) revert SupplyExhausted();

        nativeReserve += (msg.value - fee);
        tokenReserve -= tokensOut;

        // curve inventory -> buyer. No mint: supply is fixed.
        balanceOf[address(this)] -= tokensOut;
        balanceOf[msg.sender] += tokensOut;
        emit Transfer(address(this), msg.sender, tokensOut);
        emit Bought(msg.sender, msg.value, tokensOut, fee);

        _spendOnBacking(fee);
    }

    /// @notice Sell coins back to the curve for native USDG.
    function sell(uint256 tokensIn, uint256 minNativeOut) external returns (uint256 nativeOut) {
        if (tokensIn == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < tokensIn) revert InsufficientBalance();

        uint256 fee;
        (nativeOut, fee) = quoteSell(tokensIn);
        if (nativeOut < minNativeOut) revert InsufficientOutput();

        // seller -> curve inventory. No burn: supply is fixed.
        balanceOf[msg.sender] -= tokensIn;
        balanceOf[address(this)] += tokensIn;
        emit Transfer(msg.sender, address(this), tokensIn);

        nativeReserve -= (nativeOut + fee);
        tokenReserve += tokensIn;

        emit Sold(msg.sender, tokensIn, nativeOut, fee);

        (bool ok,) = msg.sender.call{value: nativeOut}("");
        if (!ok) revert NativeTransferFailed();

        _spendOnBacking(fee);
    }

    // ---------------------------------------------------------------- redemption

    /// @notice Burn coins and take that exact fraction of the vault.
    /// @dev Pays out BEFORE reducing supply in the ratio, so backing-per-coin is unchanged
    ///      for everyone who did not redeem. This is the only path out of the vault.
    function redeem(uint256 amount) external returns (uint256 backingOut) {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        backingOut = (vault.balance() * amount) / totalSupply;

        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
        emit Redeemed(msg.sender, amount, backingOut);

        vault.payout(msg.sender, backingOut);
    }

    // ---------------------------------------------------------------- backing purchase

    /// @notice Spend collected fees on the paired asset. Anyone may call; it only ever
    ///         moves value from this contract into the vault.
    function sweepFees() external {
        _spendOnBacking(0);
    }

    /// @notice Re-probe the router for its wrapped-native address. Permissionless, and it
    ///         can only ever move `wrapped` from unset to set.
    function setWrapped() external {
        if (routerReady) return;
        (wrapped, routerReady) = _probeWrapped(address(router));
    }

    /// @dev Raw staticcall so a router that is not (yet) a contract returns address(0)
    ///      instead of reverting the whole transaction.
    function _probeWrapped(address router_) internal view returns (address, bool) {
        if (router_.code.length == 0) return (address(0), false);
        (bool ok, bytes memory data) =
            router_.staticcall(abi.encodeWithSelector(IBackingRouter.WETH.selector));
        if (!ok || data.length < 32) return (address(0), false);
        return (abi.decode(data, (address)), true);
    }

    function _spendOnBacking(uint256 newFee) internal {
        uint256 spend = pendingFees + newFee;
        if (spend == 0) return;

        if (!routerReady) {
            pendingFees = spend;
            emit BackingBuyFailed(spend);
            return;
        }

        address[] memory path = new address[](2);
        path[0] = wrapped;
        path[1] = address(backing);

        // Quote first so a thin or missing pool cannot hand us a terrible fill.
        uint256 minOut;
        try router.getAmountsOut(spend, path) returns (uint256[] memory q) {
            minOut = (q[q.length - 1] * (10_000 - maxSlippageBps)) / 10_000;
        } catch {
            pendingFees = spend;
            emit BackingBuyFailed(spend);
            return;
        }
        if (minOut == 0) {
            pendingFees = spend;
            emit BackingBuyFailed(spend);
            return;
        }

        try router.swapExactETHForTokens{value: spend}(
            minOut, path, address(vault), block.timestamp
        ) returns (uint256[] memory amounts) {
            pendingFees = 0;
            emit BackingBought(spend, amounts[amounts.length - 1]);
        } catch {
            // Fee stays here and is retried on the next trade. It is never refundable
            // and there is no function that can send it anywhere but the vault.
            pendingFees = spend;
            emit BackingBuyFailed(spend);
        }
    }

    // ---------------------------------------------------------------- ERC20 plumbing

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientBalance();
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @dev Native arriving outside `buy` (e.g. a router refund) is treated as fee.
    receive() external payable {
        pendingFees += msg.value;
    }
}
