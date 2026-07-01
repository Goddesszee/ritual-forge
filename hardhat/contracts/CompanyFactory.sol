// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AutonomousCompany.sol";

// ================================================================
//  CompanyFactory — Ritual Chain
//
//  Deploys new AutonomousCompany instances. Each call spins up a
//  fresh, self-funding, self-scheduling on-chain "company" with its
//  own treasury and its own LLM-precompile-driven job.
// ================================================================

contract CompanyFactory {
    struct CompanyInfo {
        address addr;
        address owner;
        string companyType;
        uint256 feePerRequest;
        uint256 createdAt;
    }

    CompanyInfo[] public companies;
    mapping(address => uint256[]) public companiesByOwner; // owner => indices

    event CompanyDeployed(
        address indexed companyAddress,
        address indexed owner,
        string companyType,
        uint256 feePerRequest,
        uint256 initialFunding
    );

    /// @notice Deploy a new autonomous company. Any msg.value sent becomes
    ///         the company's starting treasury and is used to pay for its
    ///         own Scheduler wake-ups.
    /// @param companyType   Short label, e.g. "Reputation Scorer"
    /// @param systemPrompt  Defines what the company does — this is its "job"
    /// @param feePerRequest Native RITUAL (wei) charged per paid service call
    function deployCompany(
        string calldata companyType,
        string calldata systemPrompt,
        uint256 feePerRequest
    ) external payable returns (address companyAddress) {
        AutonomousCompany company = new AutonomousCompany{value: msg.value}(
            msg.sender,
            companyType,
            systemPrompt,
            feePerRequest
        );
        companyAddress = address(company);

        companies.push(CompanyInfo({
            addr: companyAddress,
            owner: msg.sender,
            companyType: companyType,
            feePerRequest: feePerRequest,
            createdAt: block.timestamp
        }));
        companiesByOwner[msg.sender].push(companies.length - 1);

        company.start();

        emit CompanyDeployed(companyAddress, msg.sender, companyType, feePerRequest, msg.value);
    }

    function getAllCompanies() external view returns (CompanyInfo[] memory) {
        return companies;
    }

    function getCompanyCount() external view returns (uint256) {
        return companies.length;
    }

    function getCompaniesByOwner(address ownerAddr) external view returns (CompanyInfo[] memory) {
        uint256[] memory idx = companiesByOwner[ownerAddr];
        CompanyInfo[] memory result = new CompanyInfo[](idx.length);
        for (uint256 i = 0; i < idx.length; i++) {
            result[i] = companies[idx[i]];
        }
        return result;
    }
}
