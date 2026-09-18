// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrintCoin} from "./PrintCoin.sol";

/// @title PrintFactory
/// @notice The launchpad. Anyone with a wallet calls `launch` and gets a coin whose fees
///         buy a real asset into a vault nobody can sell out of.
///
/// The factory holds no funds, has no owner and cannot touch a coin after it is created.
/// It exists to deploy pairs and to be the one place the board reads from.
contract PrintFactory {
    struct Pair {
        address coin;
        address vault;
        address backing;
        address creator;
        uint64 createdAt;
    }

    Pair[] public pairs;
    mapping(address => uint256) public indexOfCoin; // coin => pairs index + 1
    /// @notice The swap venue every coin spends its fees through.
    address public immutable router;

    /// @notice Defaults a launcher can accept rather than reasoning about curve maths.
    uint256 public constant DEFAULT_SUPPLY = 1_000_000_000 ether;
    uint256 public constant DEFAULT_VIRTUAL_NATIVE = 30 ether;
    uint16 public constant DEFAULT_FEE_BPS = 100; // 1% each side
    /// @notice Wide by design — see the measurements in PrintCoin.maxSlippageBps.
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 3000; // 30%

    event Launched(
        address indexed coin,
        address indexed vault,
        address indexed backing,
        address creator,
        string name,
        string symbol
    );

    error BadBacking();

    constructor(address router_) {
        router = router_;
    }

    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    /// @notice Launch a coin paired to `backing` on the default curve.
    function launch(string calldata name_, string calldata symbol_, address backing_)
        external
        returns (address coin)
    {
        return launchWith(
            name_, symbol_, backing_, DEFAULT_SUPPLY, DEFAULT_VIRTUAL_NATIVE,
            DEFAULT_FEE_BPS, DEFAULT_SLIPPAGE_BPS
        );
    }

    /// @notice Launch with explicit curve parameters.
    function launchWith(
        string calldata name_,
        string calldata symbol_,
        address backing_,
        uint256 supply_,
        uint256 virtualNative_,
        uint16 feeBps_,
        uint16 maxSlippageBps_
    ) public returns (address coin) {
        if (backing_ == address(0) || backing_.code.length == 0) revert BadBacking();

        PrintCoin c =
            new PrintCoin(
                name_, symbol_, supply_, virtualNative_, feeBps_, backing_, router,
                maxSlippageBps_
            );
        coin = address(c);

        pairs.push(
            Pair({
                coin: coin,
                vault: address(c.vault()),
                backing: backing_,
                creator: msg.sender,
                createdAt: uint64(block.timestamp)
            })
        );
        indexOfCoin[coin] = pairs.length;

        emit Launched(coin, address(c.vault()), backing_, msg.sender, name_, symbol_);
    }

    /// @notice Everything the board needs, in one call.
    function boardRow(uint256 i)
        external
        view
        returns (
            address coin,
            address backing,
            address creator,
            uint64 createdAt,
            string memory name,
            string memory symbol,
            uint256 supply,
            uint256 vaultBalance,
            uint256 backingPerToken,
            uint256 nativeReserve,
            uint256 tokenReserve
        )
    {
        Pair memory p = pairs[i];
        PrintCoin c = PrintCoin(payable(p.coin));
        return (
            p.coin,
            p.backing,
            p.creator,
            p.createdAt,
            c.name(),
            c.symbol(),
            c.totalSupply(),
            c.vault().balance(),
            c.backingPerToken(),
            c.nativeReserve(),
            c.tokenReserve()
        );
    }
}
