// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBackingRouter} from "../../src/interfaces/IBackingRouter.sol";

/// @notice Stands in for a tokenised stock (NVDAx, SPACEx, XAUt, …).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        emit Approval(msg.sender, sp, amt);
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        require(balanceOf[f] >= amt, "bal");
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[f][msg.sender] = a - amt;
        }
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
        emit Transfer(f, t, amt);
        return true;
    }
}

/// @notice A constant-product native<->token pool shaped like a Uniswap V2 router.
contract MockRouter is IBackingRouter {
    MockERC20 public immutable token;
    uint256 public nativeReserve;
    uint256 public tokenReserve;
    bool public broken;

    constructor(MockERC20 token_, uint256 nativeSeed, uint256 tokenSeed) payable {
        token = token_;
        nativeReserve = nativeSeed;
        tokenReserve = tokenSeed;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function WETH() external pure returns (address) {
        return address(0xEEEE);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        require(!broken, "router down");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (tokenReserve * amountIn) / (nativeReserve + amountIn);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        require(!broken, "router down");
        uint256 out = (tokenReserve * msg.value) / (nativeReserve + msg.value);
        require(out >= amountOutMin, "slippage");
        nativeReserve += msg.value;
        tokenReserve -= out;
        token.mint(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = out;
    }

    receive() external payable {}
}
