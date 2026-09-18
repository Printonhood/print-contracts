// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The swap venue the fee is spent through to acquire the backing asset.
/// Shaped like a Uniswap-V2 router so any V2-style DEX on Robinhood Chain can be used
/// without changing the coin. USDG is the chain's NATIVE currency, so the fee is spent
/// as msg.value, not as an ERC20.
interface IBackingRouter {
    /// @notice Spend `msg.value` of native USDG on `path` and send the output to `to`.
    /// @return amounts amounts[0] is the native spent, amounts[last] is the asset received.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Quote for `swapExactETHForTokens`, used to set a slippage bound.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /// @notice The wrapped-native address the path must start with.
    function WETH() external view returns (address);
}
