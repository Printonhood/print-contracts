// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title PrintVault
/// @notice Holds the backing asset for one Print coin.
///
/// There is deliberately no owner, no admin, no pause, no rescue and no upgrade path.
/// The ONLY way an asset leaves this contract is `payout`, which only the coin contract
/// can call, and which the coin only calls from `redeem` — a holder burning their coins
/// for their share. Nobody, including whoever deployed it, can sell what is in here.
contract PrintVault {
    /// @notice The coin this vault backs. Immutable, set once at construction.
    address public immutable coin;
    /// @notice The backing asset held for holders (a tokenised stock, currency, metal, …).
    IERC20 public immutable asset;

    error OnlyCoin();
    error TransferFailed();

    event PaidOut(address indexed to, uint256 amount);

    constructor(address coin_, address asset_) {
        coin = coin_;
        asset = IERC20(asset_);
    }

    /// @notice Backing currently held, in units of `asset`.
    function balance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Send a redeemer their share. Callable only by the coin contract.
    function payout(address to, uint256 amount) external {
        if (msg.sender != coin) revert OnlyCoin();
        if (amount == 0) return;
        if (!asset.transfer(to, amount)) revert TransferFailed();
        emit PaidOut(to, amount);
    }
}
