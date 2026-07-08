// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  ForgeToken (FORGE) — minimal ERC20 for the Forge ecosystem.
//
//  Includes a public faucet so anyone can claim demo FORGE without
//  needing to already hold any before the swap pool exists. Paired
//  1:1 in liquidity terms against native RITUAL via RitualForgeSwap.
// ================================================================

contract ForgeToken {
    string public constant name = "Forge Token";
    string public constant symbol = "FORGE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public lastFaucetClaim;

    uint256 public constant FAUCET_AMOUNT = 100 * 1e18;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FaucetClaim(address indexed to, uint256 amount);

    constructor(uint256 initialSupply) {
        _mint(msg.sender, initialSupply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Anyone can claim demo FORGE once per hour, so testers can
    ///         try the swap without already holding any.
    function faucet() external {
        require(block.timestamp >= lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN, "faucet cooldown active");
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaim(msg.sender, FAUCET_AMOUNT);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
