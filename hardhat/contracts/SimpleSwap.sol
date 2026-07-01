// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ================================================================
//  SimpleSwap — minimal constant-product AMM (x * y = k), 0.3% fee.
//
//  A single fixed pair pool. Deliberately small and auditable rather
//  than a full Uniswap V2 clone — this exists to demo a real, working
//  on-chain swap against seeded testnet liquidity, not to be a
//  production DEX.
// ================================================================

contract SimpleSwap {
    IERC20Min public immutable tokenA;
    IERC20Min public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant BPS_DENOM = 10000;

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 sharesMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 sharesBurned);
    event Swap(address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20Min(_tokenA);
        tokenB = IERC20Min(_tokenB);
    }

    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 mintedShares) {
        require(amountA > 0 && amountB > 0, "zero amount");
        require(tokenA.transferFrom(msg.sender, address(this), amountA), "tokenA transfer failed");
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "tokenB transfer failed");

        if (totalShares == 0) {
            mintedShares = _sqrt(amountA * amountB);
        } else {
            uint256 shareA = (amountA * totalShares) / reserveA;
            uint256 shareB = (amountB * totalShares) / reserveB;
            mintedShares = shareA < shareB ? shareA : shareB;
        }
        require(mintedShares > 0, "insufficient liquidity minted");

        reserveA += amountA;
        reserveB += amountB;
        totalShares += mintedShares;
        shares[msg.sender] += mintedShares;

        emit LiquidityAdded(msg.sender, amountA, amountB, mintedShares);
    }

    function removeLiquidity(uint256 sharesToBurn) external returns (uint256 amountA, uint256 amountB) {
        require(sharesToBurn > 0 && shares[msg.sender] >= sharesToBurn, "insufficient shares");

        amountA = (sharesToBurn * reserveA) / totalShares;
        amountB = (sharesToBurn * reserveB) / totalShares;

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        reserveA -= amountA;
        reserveB -= amountB;

        require(tokenA.transfer(msg.sender, amountA), "tokenA transfer failed");
        require(tokenB.transfer(msg.sender, amountB), "tokenB transfer failed");

        emit LiquidityRemoved(msg.sender, amountA, amountB, sharesToBurn);
    }

    /// @notice Swap an exact amount of tokenA in for tokenB out, or vice versa.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "invalid token");
        require(amountIn > 0, "zero amount in");
        bool inIsA = tokenIn == address(tokenA);

        (uint256 reserveIn, uint256 reserveOut) = inIsA ? (reserveA, reserveB) : (reserveB, reserveA);
        require(reserveIn > 0 && reserveOut > 0, "no liquidity");

        uint256 amountInWithFee = amountIn * (BPS_DENOM - FEE_BPS);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * BPS_DENOM + amountInWithFee);
        require(amountOut >= minAmountOut, "slippage exceeded");

        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        if (inIsA) {
            reserveA += amountIn;
            reserveB -= amountOut;
            tokenB.transfer(msg.sender, amountOut);
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
            tokenA.transfer(msg.sender, amountOut);
        }

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    /// @notice Quote-only estimate, does not execute a swap.
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        bool inIsA = tokenIn == address(tokenA);
        (uint256 reserveIn, uint256 reserveOut) = inIsA ? (reserveA, reserveB) : (reserveB, reserveA);
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * (BPS_DENOM - FEE_BPS);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * BPS_DENOM + amountInWithFee);
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
}
