// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DCABot.sol";

// ================================================================
//  DCABotFactory — Ritual Chain
//
//  Deploys new DCABot instances. Each call spins up a fresh,
//  self-funding, self-scheduling agent that DCAs RITUAL into FORGE
//  via the shared swap pool. Structured identically to
//  CompanyFactory.sol on purpose — same ownership-passing pattern
//  (explicit _owner param, not msg.sender inside the child
//  contract's own constructor, since msg.sender there would be this
//  factory, not the real caller).
// ================================================================

contract DCABotFactory {
    address public immutable swapAddress;
    address public immutable forgeToken;

    struct BotInfo {
        address addr;
        address owner;
        uint256 swapAmountPerCycle;
        uint256 createdAt;
    }

    BotInfo[] public bots;
    mapping(address => uint256[]) public botsByOwner;

    event BotDeployed(
        address indexed botAddress,
        address indexed owner,
        uint256 swapAmountPerCycle,
        uint256 initialFunding
    );

    constructor(address _swapAddress, address _forgeToken) {
        swapAddress = _swapAddress;
        forgeToken = _forgeToken;
    }

    /// @notice Deploy a new DCA bot. Any msg.value sent becomes its
    ///         starting balance — needs to comfortably cover the
    ///         Scheduler escrow deposit (0.06 RITUAL) plus room for
    ///         actual swap cycles on top of that.
    /// @param swapAmountPerCycle RITUAL (wei) spent on FORGE every wake cycle
    function deployBot(uint256 swapAmountPerCycle) external payable returns (address botAddress) {
        require(swapAmountPerCycle > 0, "swap amount must be > 0");

        DCABot bot = new DCABot{value: msg.value}(
            msg.sender,
            swapAddress,
            forgeToken,
            swapAmountPerCycle
        );
        botAddress = address(bot);

        bots.push(BotInfo({
            addr: botAddress,
            owner: msg.sender,
            swapAmountPerCycle: swapAmountPerCycle,
            createdAt: block.timestamp
        }));
        botsByOwner[msg.sender].push(bots.length - 1);

        emit BotDeployed(botAddress, msg.sender, swapAmountPerCycle, msg.value);
    }

    function getAllBots() external view returns (BotInfo[] memory) {
        return bots;
    }

    function getBotCount() external view returns (uint256) {
        return bots.length;
    }

    function getBotsByOwner(address ownerAddr) external view returns (BotInfo[] memory) {
        uint256[] memory idx = botsByOwner[ownerAddr];
        BotInfo[] memory result = new BotInfo[](idx.length);
        for (uint256 i = 0; i < idx.length; i++) {
            result[i] = bots[idx[i]];
        }
        return result;
    }
}
