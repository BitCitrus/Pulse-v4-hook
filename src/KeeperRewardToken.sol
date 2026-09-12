// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title KeeperRewardToken
/// @notice ERC20 token for keeper rewards. All supply minted to deployer at deployment.
contract KeeperRewardToken is IERC20Minimal {
    string public constant NAME = "PulseV4 Keeper Reward";
    string public constant SYMBOL = "PV4-KR";

    uint256 public constant TOTAL_SUPPLY = 1e18 * 1e6; // 1 million tokens (1e6 * 1e18)

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    uint256 public totalSupply;

    /// @notice Constructor mints entire supply to the deployer (msg.sender)
    constructor() {
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        totalSupply = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        uint256 b = balanceOf[msg.sender];
        require(b >= amount, "INSUFFICIENT_BALANCE");
        balanceOf[msg.sender] = b - amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE_EXCEEDED");
        allowance[from][msg.sender] = allowed - amount;

        uint256 fromBal = balanceOf[from];
        require(fromBal >= amount, "INSUFFICIENT_BALANCE");
        balanceOf[from] = fromBal - amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
        return true;
    }
}
