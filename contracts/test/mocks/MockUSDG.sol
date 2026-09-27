// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Test double only, a standard 6-decimal USDG stand-in. Nothing in src/ imports this. The real
// deploy uses the live Paxos USDG on Arbitrum Sepolia (0xFFC95faa3d63Cde504a05B567C600B78C0b41892),
// never this mock.
contract MockUSDG {
    string public name = "USDG";
    string public symbol = "USDG";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
