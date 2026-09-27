// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Test double for the Arbitrum L2 Sequencer Uptime Status Feed (SECURITY-REVIEW.md M2).
// `answer == 0` means the sequencer is up (real feed's convention); `startedAt` is when that
// status began, used by Treaty._requireSequencerUp for the grace-period check.
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;

    constructor() {
        startedAt = block.timestamp - 1 days; // up, well past grace, by default
    }

    function setDown() external {
        answer = 1;
        startedAt = block.timestamp;
    }

    function setUp(uint256 upSince) external {
        answer = 0;
        startedAt = upSince;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}
