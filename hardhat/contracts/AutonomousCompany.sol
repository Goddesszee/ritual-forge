// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  AutonomousCompany — Ritual Chain
//
//  A single spawned "company": self-funding treasury, self-waking
//  Scheduler loop, and an LLM-precompile-driven service any caller
//  can pay to use. No employees. No off-chain server. No owner
//  action required to keep operating.
//
//  Precompiles used:
//    0x0802 — LLM        (service delivery + heartbeat reasoning, TEE-attested)
//    Scheduler system contract — self-waking every WAKE_INTERVAL blocks
//
//  LLM integration follows Ritual's documented 30-field request ABI
//  and TEEServiceRegistry executor lookup exactly (ritual-dapp-llm
//  skill, Section 7 Solidity Consumer Contract pattern) — the earlier
//  simplified struct-based interface did not match the real precompile
//  and every call failed with "ethabi decode failed".
// ================================================================

interface IScheduler {
    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer,
        address predicate
    ) external returns (uint256 callId);
    function cancel(uint256 callId) external;
}

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
}

interface ITEEServiceRegistry {
    struct TEENode {
        address paymentAddress;
        address teeAddress;
        uint8 teeType;
        bytes publicKey;
        string endpoint;
        bytes32 certPubKeyHash;
        uint8 capability;
    }
    struct TEEService {
        TEENode node;
        bool isValid;
        bytes32 workloadId;
    }
    function getServicesByCapability(uint8 capability, bool checkValidity)
        external view returns (TEEService[] memory);
}

contract AutonomousCompany {
    struct StorageRef { string platform; string path; string keyRef; }

    address internal constant LLM = 0x0000000000000000000000000000000000000802;
    address internal constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address internal constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;
    address internal constant TEE_REGISTRY = 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F;
    uint8 internal constant CAPABILITY_LLM = 1;
    string internal constant MODEL = "zai-org/GLM-4.7-FP8";

    uint32 public constant WAKE_INTERVAL = 500; // ~3 min on Ritual testnet
    uint256 public constant SCHEDULER_FEE_DEPOSIT = 0.005 ether;
    uint256 public constant SCHEDULER_LOCK_DURATION = 50000;

    // ── Identity ────────────────────────────────────────────────
    address public factory;
    address public owner;
    string public companyType;     // e.g. "Reputation Scorer"
    string public systemPrompt;    // defines the company's job for the LLM
    uint256 public feePerRequest;  // native RITUAL, in wei

    // ── Lifecycle state ─────────────────────────────────────────
    bool public running;
    uint256 public scheduleId;
    uint256 public wakeCount;
    uint256 public requestCount;
    uint256 public totalRevenue;
    uint256 public lastWakeBlock;
    uint256 public createdAt;
    string public lastHeartbeat;

    struct ServiceLog {
        address requester;
        string input;
        string output;
        uint256 timestamp;
    }
    ServiceLog[] private _log;
    uint256 public constant MAX_LOG = 20;

    event CompanyStarted(uint256 atBlock);
    event WokeUp(uint256 wakeCount, uint256 atBlock, string note);
    event ServiceDelivered(address indexed requester, uint256 fee, string output);
    event Withdrawn(address indexed to, uint256 amount);

    error OnlyOwner();
    error OnlyScheduler();
    error OnlyFactory();
    error AlreadyRunning();
    error InsufficientFee();
    error DepositFailed();
    error ScheduleFailed();
    error NoExecutorAvailable();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        address _owner,
        string memory _companyType,
        string memory _systemPrompt,
        uint256 _feePerRequest
    ) payable {
        factory = msg.sender;
        owner = _owner;
        companyType = _companyType;
        systemPrompt = _systemPrompt;
        feePerRequest = _feePerRequest;
        createdAt = block.timestamp;
    }

    // ══════════════════════════════════════════════════════════
    //  LIFECYCLE — self-waking via Scheduler
    // ══════════════════════════════════════════════════════════

    function start() external {
        if (msg.sender != owner && msg.sender != factory) revert OnlyOwner();
        if (running) revert AlreadyRunning();
        running = true;
        _fundWallet();
        scheduleId = _scheduleWakeup(WAKE_INTERVAL);
        emit CompanyStarted(block.number);
    }

    /// @notice Step 1 only, callable independently for isolated testing.
    function fundWalletOnly() external onlyOwner {
        _fundWallet();
    }

    /// @notice Step 2 only, callable independently for isolated testing.
    function scheduleOnly() external onlyOwner returns (uint256) {
        return _scheduleWakeup(WAKE_INTERVAL);
    }

    function _fundWallet() internal {
        uint256 depositAmount = SCHEDULER_FEE_DEPOSIT;
        if (address(this).balance < depositAmount) {
            depositAmount = address(this).balance;
        }
        if (depositAmount > 0) {
            (bool depOk, bytes memory depResult) = RITUAL_WALLET.call{value: depositAmount}(
                abi.encodeWithSelector(IRitualWallet.deposit.selector, SCHEDULER_LOCK_DURATION)
            );
            if (!depOk) {
                assembly {
                    revert(add(depResult, 32), mload(depResult))
                }
            }
        }
    }

    function wakeUp(uint256) external {
        if (msg.sender != SCHEDULER) revert OnlyScheduler();
        if (!running) return;

        wakeCount++;
        lastWakeBlock = block.number;
        try this._callLLM(
            systemPrompt,
            "Routine heartbeat check. In under 15 words, state your operating status and readiness for new requests.",
            256
        ) returns (bool, string memory content, string memory errMsg) {
            lastHeartbeat = bytes(content).length > 0 ? content : errMsg;
        } catch Error(string memory reason) {
            lastHeartbeat = string(abi.encodePacked("llm call reverted: ", reason));
        } catch (bytes memory) {
            lastHeartbeat = "llm call reverted (no reason)";
        }

        scheduleId = _scheduleWakeup(WAKE_INTERVAL);
        emit WokeUp(wakeCount, block.number, lastHeartbeat);
    }

    function stop() external onlyOwner {
        running = false;
        if (scheduleId != 0) {
            IScheduler(SCHEDULER).cancel(scheduleId);
        }
    }

    function _scheduleWakeup(uint32 delay) internal returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, uint256(0));

        (bool ok, bytes memory result) = SCHEDULER.call(
            abi.encodeWithSelector(
                IScheduler.schedule.selector,
                data,
                uint32(300000),
                uint32(block.number) + delay,
                uint32(1),
                uint32(1),
                uint32(100),
                block.basefee + 1 gwei,
                uint256(0),
                uint256(0),
                address(this),
                address(0)
            )
        );
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return abi.decode(result, (uint256));
    }

    // ══════════════════════════════════════════════════════════
    //  LLM — real 30-field precompile call per ritual-dapp-llm skill
    // ══════════════════════════════════════════════════════════

    function _getExecutor() internal view returns (address) {
        ITEEServiceRegistry.TEEService[] memory services =
            ITEEServiceRegistry(TEE_REGISTRY).getServicesByCapability(CAPABILITY_LLM, true);
        if (services.length == 0) revert NoExecutorAvailable();
        return services[0].node.teeAddress;
    }

    function _callLLM(string memory sysPrompt, string memory userContent, uint256 maxTokens)
        external
        returns (bool hasError, string memory content, string memory errorMessage)
    {
        if (msg.sender != address(this)) revert OnlyOwner();
        address executor = _getExecutor();

        string memory messagesJson = string(
            abi.encodePacked(
                '[{"role":"system","content":"', _escapeJson(sysPrompt), '"},',
                '{"role":"user","content":"', _escapeJson(userContent), '"}]'
            )
        );

        bytes memory input = abi.encode(
            executor,
            new bytes[](0),      // encryptedSecrets
            uint256(300),        // ttl
            new bytes[](0),      // secretSignatures
            bytes(""),           // userPublicKey
            messagesJson,
            MODEL,
            int256(0),           // frequencyPenalty
            "",                  // logitBiasJson
            false,               // logprobs
            int256(maxTokens),   // maxCompletionTokens
            "",                  // metadataJson
            "",                  // modalitiesJson
            uint256(1),          // n
            true,                // parallelToolCalls
            int256(0),           // presencePenalty
            "medium",            // reasoningEffort
            bytes(""),           // responseFormatData
            int256(-1),          // seed
            "auto",              // serviceTier
            "",                  // stopJson
            false,               // stream
            int256(700),         // temperature (0.7 * 1000)
            bytes(""),           // toolChoiceData
            bytes(""),           // toolsData
            int256(-1),          // topLogprobs
            int256(1000),        // topP (1.0 * 1000)
            "",                  // user
            false,               // piiEnabled
            StorageRef("", "", "") // convoHistory: must be an inline (string,string,string) tuple,
                                    // NOT a separately abi.encode()'d bytes blob — that was the bug.
        );

        (bool ok, bytes memory result) = LLM.call(input);
        if (!ok) {
            return (true, "", "LLM precompile call failed");
        }

        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));

        bytes memory completionData;
        (hasError, completionData, , errorMessage, ) = abi.decode(
            actualOutput, (bool, bytes, bytes, string, StorageRef)
        );

        if (hasError || completionData.length == 0) {
            return (hasError, "", errorMessage);
        }

        content = _extractContent(completionData);
    }

    function _extractContent(bytes memory completionData) internal pure returns (string memory) {
        (, , , , , , uint256 choicesCount, bytes[] memory choicesData, ) = abi.decode(
            completionData, (string, string, uint256, string, string, string, uint256, bytes[], bytes)
        );

        if (choicesCount == 0 || choicesData.length == 0) {
            return "";
        }

        (, , bytes memory messageData) = abi.decode(choicesData[0], (uint256, string, bytes));
        (, string memory msgContent, , , ) = abi.decode(
            messageData, (string, string, string, uint256, bytes[])
        );
        return msgContent;
    }

    function _escapeJson(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);
        bytes memory result = new bytes(b.length * 2);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                result[j++] = "\\";
                result[j++] = c;
            } else if (c == 0x0A) {
                result[j++] = "\\";
                result[j++] = "n";
            } else {
                result[j++] = c;
            }
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 k = 0; k < j; k++) trimmed[k] = result[k];
        return string(trimmed);
    }

    // ══════════════════════════════════════════════════════════
    //  PAID SERVICE — any caller pays feePerRequest to use the company
    // ══════════════════════════════════════════════════════════

    function requestService(string calldata input) external payable returns (string memory output) {
        if (msg.value < feePerRequest) revert InsufficientFee();
        totalRevenue += msg.value;
        requestCount++;

        try this._callLLM(systemPrompt, input, 4096) returns (bool, string memory content, string memory errMsg) {
            output = bytes(content).length > 0 ? content : errMsg;
        } catch Error(string memory reason) {
            output = string(abi.encodePacked("llm call reverted: ", reason));
        } catch (bytes memory) {
            output = "llm call reverted (no reason available)";
        }

        _pushLog(msg.sender, input, output);
        emit ServiceDelivered(msg.sender, msg.value, output);
    }

    function _pushLog(address requester, string memory input, string memory output) internal {
        if (_log.length >= MAX_LOG) {
            for (uint256 i = 0; i < _log.length - 1; i++) {
                _log[i] = _log[i + 1];
            }
            _log.pop();
        }
        _log.push(ServiceLog(requester, input, output, block.timestamp));
    }

    function getRecentLog() external view returns (ServiceLog[] memory) {
        return _log;
    }

    // ══════════════════════════════════════════════════════════
    //  TREASURY
    // ══════════════════════════════════════════════════════════

    function withdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "exceeds treasury");
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(owner, amount);
    }

    function treasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
