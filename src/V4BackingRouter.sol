// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBackingRouter} from "./interfaces/IBackingRouter.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// ---------------------------------------------------------------------------
/// Minimal Uniswap V4 surface. Robinhood Chain runs V4, not V2/V3 — the canonical
/// V2/V3 router addresses hold unrelated contracts. Verified on chain 4663:
///   PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951
/// and live pools quote `currency0 = address(0)`, i.e. native USDG directly.
/// ---------------------------------------------------------------------------
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function extsload(bytes32 slot) external view returns (bytes32);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @title V4BackingRouter
/// @notice Adapts Uniswap V4 to the simple V2-shaped `IBackingRouter` that PrintCoin
///         speaks, so the coin contract stays readable and chain-agnostic.
///
/// One adapter per backing asset, because the V4 pool key (fee tier, tick spacing and
/// hook address) is per-pool and cannot be guessed. The key is immutable once deployed,
/// so nobody can repoint a live coin at a different pool.
contract V4BackingRouter is IBackingRouter {
    IPoolManager public immutable poolManager;
    address public immutable asset;

    // the pool key, stored flat so it can be immutable
    address private immutable c0;
    address private immutable c1;
    uint24 private immutable poolFee;
    int24 private immutable poolTickSpacing;
    address private immutable poolHooks;

    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE =
        1461446703485210103287273052203988822378723970342;

    error OnlyPoolManager();
    error NotNativePool();
    error NothingOut();

    constructor(IPoolManager poolManager_, PoolKey memory key) {
        // Print pays fees in native USDG, so one side of the pool must be native.
        if (key.currency0 != address(0)) revert NotNativePool();
        poolManager = poolManager_;
        c0 = key.currency0;
        c1 = key.currency1;
        poolFee = key.fee;
        poolTickSpacing = key.tickSpacing;
        poolHooks = key.hooks;
        asset = key.currency1;
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, poolFee, poolTickSpacing, poolHooks);
    }

    /// @inheritdoc IBackingRouter
    /// @dev V4 has no native "wrapped" concept — native IS currency0 — so this reports
    ///      address(0), which PrintCoin uses only as the first hop of its path.
    function WETH() external pure returns (address) {
        return address(0);
    }

    /// @notice This pool's sqrtPriceX96, read straight out of PoolManager storage.
    /// @dev V4 exposes state through `extsload`. POOLS_SLOT is 6; slot0 packs
    ///      sqrtPriceX96 into its low 160 bits.
    function sqrtPriceX96() public view returns (uint160) {
        bytes32 poolId = keccak256(abi.encode(_key()));
        bytes32 slot = keccak256(abi.encode(poolId, uint256(6)));
        return uint160(uint256(poolManager.extsload(slot)));
    }

    /// @notice A real spot quote, so the caller's slippage bound actually means something.
    /// @dev price (token1 per token0) = (sqrtP / 2**96)**2, applied in two stages because
    ///      sqrtP**2 does not fit in 256 bits. A placeholder here is not harmless: PrintCoin
    ///      multiplies this by 0.95, and if that rounds to 0 it skips the swap entirely.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        uint256 sp = uint256(sqrtPriceX96());
        if (sp == 0) return amounts; // pool uninitialised -> quote 0, caller queues the fee
        uint256 out = (amountIn * sp) >> 96;
        out = (out * sp) >> 96;
        amounts[path.length - 1] = out;
    }

    /// @notice Spend msg.value of native USDG on the pool's asset and send it to `to`.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata,
        address to,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        bytes memory res =
            poolManager.unlock(abi.encode(msg.value, amountOutMin, to));
        uint256 out = abi.decode(res, (uint256));
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }

    /// @notice PoolManager calls back here with the lock held.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (uint256 amountIn, uint256 minOut, address to) =
            abi.decode(data, (uint256, uint256, address));

        int256 delta = poolManager.swap(
            _key(),
            SwapParams({
                zeroForOne: true, // native (currency0) -> asset (currency1)
                amountSpecified: -int256(amountIn), // negative = exact input
                sqrtPriceLimitX96: MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // BalanceDelta packs amount0 in the high 128 bits, amount1 in the low 128.
        int128 amount1 = int128(int256(uint256(uint256(delta) & type(uint128).max)));
        uint256 out = amount1 > 0 ? uint256(uint128(amount1)) : 0;
        if (out < minOut || out == 0) revert NothingOut();

        // pay the native we owe, then take the asset we are owed
        poolManager.settle{value: amountIn}();
        poolManager.take(c1, to, out);

        return abi.encode(out);
    }

    receive() external payable {}
}
