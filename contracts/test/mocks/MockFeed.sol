// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Test double only, a standard Chainlink-shaped mock feed. Nothing in src/
// imports this.
contract MockFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestId;
    uint8 public constant decimals = 8;

    function set(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt);
        if (roundId > latestId) latestId = roundId;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[roundId];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}
