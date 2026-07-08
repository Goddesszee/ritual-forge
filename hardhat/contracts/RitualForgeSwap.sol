// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ================================================================
//  RitualForgeSwap — minimal constant-product AMM (x * y = k), 0.3% fee.
//
//  Single fixed pair pool: native RITUAL <-> FORGE. Unlike the earlier
//  SimpleSwap (which only swapped between two ERC20s and never actually
//  touched the chain's native currency), this contract takes RITUAL
//  directly as msg.value, so a user only needs testnet RITUAL from the
//  faucet to try it — no pre-existing FORGE required on one side.
//
//  Deliberately small and auditable rather than a full Uniswap V2
//  clone — demo-focused, not a production DEX.
// ================================================================

contract RitualForgeSwap {
    IERC20Min public immutable forgeToken;

    uint256 public reserveRitual;
    uint256 public reserveForge;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant BPS_DENOM = 10000;

    event LiquidityAdded(address indexed provider, uint256 ritualIn, uint256 forgeIn, uint256 sharesMinted);
    event LiquidityRemoved(address indexed provider, uint256 ritualOut, uint256 forgeOut, uint256 sharesBurned);
    event SwapRitualForForge(address indexed trader, uint256 ritualIn, uint256 forgeOut);
    event SwapForgeForRitual(address indexed trader, uint256 forgeIn, uint256 ritualOut);

    constructor(address _forgeToken) {
        forgeToken = IERC20Min(_forgeToken);
    }

    /// @notice Seed or add liquidity. Send RITUAL as msg.value; the caller
    ///         must have approved this contract for `forgeAmount` FORGE first.
    function addLiquidity(uint256 forgeAmount) external payable returns (uint256 mintedShares) {
        require(msg.value > 0 && forgeAmount > 0, "zero amount");
        require(forgeToken.transferFrom(msg.sender, address(this), forgeAmount), "forge transfer failed");

        if (totalShares == 0) {
            mintedShares = _sqrt(msg.value * forgeAmount);
        } else {
            uint256 shareR = (msg.value * totalShares) / reserveRitual;
            uint256 shareF = (forgeAmount * totalShares) / reserveForge;
            mintedShares = shareR < shareF ? shareR : shareF;
        }
        require(mintedShares > 0, "insufficient liquidity minted");

        reserveRitual += msg.value;
        reserveForge += forgeAmount;
        totalShares += mintedShares;
        shares[msg.sender] += mintedShares;

        emit LiquidityAdded(msg.sender, msg.value, forgeAmount, mintedShares);
    }

    function removeLiquidity(uint256 sharesToBurn) external returns (uint256 ritualOut, uint256 forgeOut) {
        require(sharesToBurn > 0 && shares[msg.sender] >= sharesToBurn, "insufficient shares");

        ritualOut = (sharesToBurn * reserveRitual) / totalShares;
        forgeOut = (sharesToBurn * reserveForge) / totalShares;

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        reserveRitual -= ritualOut;
        reserveForge -= forgeOut;

        (bool ok, ) = payable(msg.sender).call{value: ritualOut}("");
        require(ok, "ritual payout failed");
        require(forgeToken.transfer(msg.sender, forgeOut), "forge transfer failed");

        emit LiquidityRemoved(msg.sender, ritualOut, forgeOut, sharesToBurn);
    }

    /// @notice Swap native RITUAL (sent as msg.value) for FORGE.
    function swapRitualForForge(uint256 minForgeOut) external payable returns (uint256 forgeOut) {
        require(msg.value > 0, "zero amount in");
        require(reserveRitual > 0 && reserveForge > 0, "no liquidity");

        uint256 amountInWithFee = msg.value * (BPS_DENOM - FEE_BPS);
        forgeOut = (amountInWithFee * reserveForge) / (reserveRitual * BPS_DENOM + amountInWithFee);
        require(forgeOut >= minForgeOut, "slippage exceeded");

        reserveRitual += msg.value;
        reserveForge -= forgeOut;
        require(forgeToken.transfer(msg.sender, forgeOut), "forge transfer failed");

        emit SwapRitualForForge(msg.sender, msg.value, forgeOut);
    }

    /// @notice Swap FORGE for native RITUAL. Caller must approve first.
    function swapForgeForRitual(uint256 forgeAmountIn, uint256 minRitualOut) external returns (uint256 ritualOut) {
        require(forgeAmountIn > 0, "zero amount in");
        require(reserveRitual > 0 && reserveForge > 0, "no liquidity");

        require(forgeToken.transferFrom(msg.sender, address(this), forgeAmountIn), "forge transfer failed");

        uint256 amountInWithFee = forgeAmountIn * (BPS_DENOM - FEE_BPS);
        ritualOut = (amountInWithFee * reserveRitual) / (reserveForge * BPS_DENOM + amountInWithFee);
        require(ritualOut >= minRitualOut, "slippage exceeded");

        reserveForge += forgeAmountIn;
        reserveRitual -= ritualOut;
        (bool ok, ) = payable(msg.sender).call{value: ritualOut}("");
        require(ok, "ritual payout failed");

        emit SwapForgeForRitual(msg.sender, forgeAmountIn, ritualOut);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserveRitual, reserveForge);
    }

    /// @notice Quote-only estimate for a RITUAL -> FORGE swap. Does not execute.
    function quoteRitualToForge(uint256 ritualIn) external view returns (uint256) {
        if (reserveRitual == 0 || reserveForge == 0) return 0;
        uint256 amountInWithFee = ritualIn * (BPS_DENOM - FEE_BPS);
        return (amountInWithFee * reserveForge) / (reserveRitual * BPS_DENOM + amountInWithFee);
    }

    /// @notice Quote-only estimate for a FORGE -> RITUAL swap. Does not execute.
    function quoteForgeToRitual(uint256 forgeIn) external view returns (uint256) {
        if (reserveRitual == 0 || reserveForge == 0) return 0;
        uint256 amountInWithFee = forgeIn * (BPS_DENOM - FEE_BPS);
        return (amountInWithFee * reserveRitual) / (reserveForge * BPS_DENOM + amountInWithFee);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    receive() external payable {}
}
