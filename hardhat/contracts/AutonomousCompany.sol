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
    // 10-param signature per Ritual's official documented example
    // (docs.ritualfoundation.org — Scheduled Transactions). There is no
    // trailing `predicate` argument on this function; predicates are a
    // separate conditional-execution mechanism, not an 11th positional
    // param here. The earlier 11-param version was the root cause of
    // every `schedule()` revert recorded in RITUAL_BUG_REPORT.md.
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
        address payer
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
    // Scheduler escrows the full worst-case cost upfront: gas * maxFeePerGas
    // * numCalls = 800,000 * 20 gwei * 3 = 0.048 RITUAL exactly (see
    // _scheduleWakeupCall). The old 0.005 RITUAL deposit was ~10x short of
    // that — confirmed via RitualWallet.balanceOf() against a live stuck
    // company — and was the true root cause of every 0x13a6fe64 revert,
    // not the earlier signature/parameter guesses. Set comfortably above
    // the 0.048 RITUAL floor so real gas variance doesn't reintroduce it.
    uint256 public constant SCHEDULER_FEE_DEPOSIT = 0.06 ether; // initial deposit at start()
    uint256 public constant SCHEDULER_LOCK_DURATION = 50000;
    uint256 public constant WAKE_TOPUP_AMOUNT = 0.0005 ether; // small trickle top-up every wake

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
    /// @notice Emitted when a wake-up succeeds but the self-reschedule fails.
    ///         The company is still `running` but has no live Scheduler
    ///         callback — call `kick()` to recover instead of losing it.
    event RescheduleFailed(uint256 atBlock, bytes reason);
    /// @notice Emitted when `kick()` successfully re-arms a stalled company.
    event Kicked(uint256 newScheduleId, uint256 atBlock);
    /// @notice Emitted when a periodic RitualWallet top-up (from wakeUp)
    ///         fails to send. Non-fatal — the wake-up still completes.
    event WalletTopUpFailed(uint256 attempted);

    error OnlyOwner();
    error OnlyScheduler();
    error AlreadyRunning();
    error NotRunning();
    error InsufficientFee();
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
        _fundWallet(SCHEDULER_FEE_DEPOSIT);
        scheduleId = _scheduleWakeupOrRevert(WAKE_INTERVAL);
        emit CompanyStarted(block.number);
    }

    /// @notice Step 1 only, callable independently for isolated testing.
    function fundWalletOnly() external onlyOwner {
        _fundWallet(SCHEDULER_FEE_DEPOSIT);
    }

    /// @notice Step 2 only, callable independently for isolated testing.
    function scheduleOnly() external onlyOwner returns (uint256) {
        return _scheduleWakeupOrRevert(WAKE_INTERVAL);
    }

    /// @notice Recovery valve. If a wake-up's self-reschedule ever fails
    ///         (see RescheduleFailed), the company is left `running` with
    ///         no live Scheduler callback and would otherwise be dead
    ///         forever. Owner calls this to re-fund and re-arm it —
    ///         no need to stop() first.
    function kick() external onlyOwner {
        if (!running) revert NotRunning();
        _fundWallet(SCHEDULER_FEE_DEPOSIT);
        scheduleId = _scheduleWakeupOrRevert(WAKE_INTERVAL);
        emit Kicked(scheduleId, block.number);
    }

    /// @notice Deposits up to `amount` (capped by current balance) into
    ///         RitualWallet. Reverts on failure — used at start() where
    ///         we want to know immediately if funding didn't work.
    function _fundWallet(uint256 amount) internal {
        uint256 depositAmount = amount;
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

    /// @notice Same deposit, but never reverts. Used inside wakeUp() so a
    ///         top-up hiccup can't take down the whole heartbeat.
    function _tryTopUpWallet(uint256 amount) internal returns (bool) {
        uint256 depositAmount = amount;
        if (address(this).balance < depositAmount) {
            depositAmount = address(this).balance;
        }
        if (depositAmount == 0) return true;
        (bool depOk, ) = RITUAL_WALLET.call{value: depositAmount}(
            abi.encodeWithSelector(IRitualWallet.deposit.selector, SCHEDULER_LOCK_DURATION)
        );
        return depOk;
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

        // Small trickle top-up every cycle so the RitualWallet balance
        // that pays for scheduling never quietly runs dry between
        // deposits — non-reverting, since a top-up hiccup shouldn't
        // take down the heartbeat.
        if (!_tryTopUpWallet(WAKE_TOPUP_AMOUNT)) {
            emit WalletTopUpFailed(WAKE_TOPUP_AMOUNT);
        }

        // Reschedule the next wake. If this fails, DO NOT revert the whole
        // wake-up (that would erase wakeCount/heartbeat and, worse, leave
        // no on-chain trace of why the company went quiet). Instead: keep
        // this wake-up's effects, record the failure, and leave `running`
        // true with scheduleId cleared so an off-chain watcher can see it
        // and the owner can call kick() to recover.
        (bool schedOk, uint256 callId) = _scheduleWakeup(WAKE_INTERVAL);
        if (schedOk) {
            scheduleId = callId;
        } else {
            scheduleId = 0;
            emit RescheduleFailed(block.number, bytes("scheduler.schedule() reverted"));
        }

        emit WokeUp(wakeCount, block.number, lastHeartbeat);
    }

    function stop() external onlyOwner {
        running = false;
        if (scheduleId != 0) {
            IScheduler(SCHEDULER).cancel(scheduleId);
        }
    }

    /// @notice Never reverts — returns success/failure instead so callers
    ///         can decide how to react. Used inside wakeUp(), where we
    ///         want resilience over diagnostics (a failure here shouldn't
    ///         nuke the heartbeat that already happened this cycle).
    function _scheduleWakeup(uint32 delay) internal returns (bool, uint256) {
        (bool ok, bytes memory result) = _scheduleWakeupCall(delay);
        if (!ok) {
            return (false, 0);
        }
        return (true, abi.decode(result, (uint256)));
    }

    /// @notice Same call, but bubbles Scheduler's *actual* revert reason
    ///         instead of swallowing it. Used by start()/kick(), where
    ///         reverting the whole tx is already the intended behavior on
    ///         failure — so we may as well surface the real cause (e.g.
    ///         an insufficient-balance or bad-parameter error from the
    ///         Scheduler contract itself) rather than a generic message.
    function _scheduleWakeupOrRevert(uint32 delay) internal returns (uint256) {
        (bool ok, bytes memory result) = _scheduleWakeupCall(delay);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return abi.decode(result, (uint256));
    }

    function _scheduleWakeupCall(uint32 delay) private returns (bool, bytes memory) {
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, uint256(0));

        // Values match Ritual's own official "AutonomousAgent" reference
        // implementation (docs.ritualfoundation.org — "How They Stay Alive")
        // exactly: gas 800_000, numCalls 3 ("retry slots" — not a literal
        // repeat count, Scheduler's own retry attempts for this one logical
        // wake), frequency 1, ttl 30, maxFeePerGas 20 gwei, maxPriorityFeePerGas
        // 2 gwei. Our earlier numCalls=1 and dynamic-basefee fee values were
        // a guess that produced the exact 0x13a6fe64 revert seen in
        // production — these are the values from Ritual's own working example.
        return SCHEDULER.call(
            abi.encodeWithSelector(
                IScheduler.schedule.selector,
                data,
                uint32(800000),
                uint32(block.number) + delay,
                uint32(3),
                uint32(1),
                uint32(30),
                uint256(20 gwei),
                uint256(2 gwei),
                uint256(0),
                address(this)
            )
        );
    }

    // ══════════════════════════════════════════════════════════
    //  LLM — real 30-field precompile call per ritual-dapp-llm skill
    // ══════════════════════════════════════════════════════════

    function _getExecutors() internal view returns (ITEEServiceRegistry.TEEService[] memory) {
        ITEEServiceRegistry.TEEService[] memory services =
            ITEEServiceRegistry(TEE_REGISTRY).getServicesByCapability(CAPABILITY_LLM, true);
        if (services.length == 0) revert NoExecutorAvailable();
        return services;
    }

    function _callLLM(string memory sysPrompt, string memory userContent, uint256 maxTokens)
        external
        returns (bool hasError, string memory content, string memory errorMessage)
    {
        if (msg.sender != address(this)) revert OnlyOwner();

        string memory messagesJson = string(
            abi.encodePacked(
                '[{"role":"system","content":"', _escapeJson(sysPrompt), '"},',
                '{"role":"user","content":"', _escapeJson(userContent), '"}]'
            )
        );

        // Try every registered executor in order rather than only ever the
        // first one. A single executor with a stale/expired TEE attestation
        // (the builder rejects results from those — see docs on
        // TEEServiceRegistry) would otherwise permanently break every call
        // this contract makes, even while other executors and other agents
        // on the network are working fine. This is exactly the failure
        // pattern observed in production: "failed to get cert hash from
        // registry" on every attempt, while Scheduler itself stayed active
        // for other addresses the whole time.
        ITEEServiceRegistry.TEEService[] memory services = _getExecutors();
        for (uint256 i = 0; i < services.length; i++) {
            (bool ok, bool hadError, string memory outContent, string memory outError) =
                _tryLLMCall(services[i].node.teeAddress, messagesJson, maxTokens);
            if (ok) {
                return (hadError, outContent, outError);
            }
            // this executor failed outright (not just "model returned an
            // error" — the precompile call itself didn't succeed) — move
            // on and try the next registered executor.
        }
        return (true, "", "All registered executors failed (last resort: registry may be degraded)");
    }

    function _tryLLMCall(address executor, string memory messagesJson, uint256 maxTokens)
        internal
        returns (bool callOk, bool hasError, string memory content, string memory errorMessage)
    {
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
            return (false, true, "", "LLM precompile call failed");
        }

        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));

        // The precompile call itself succeeded from here on — callOk stays
        // true even if the model run itself reports an error, since that's
        // a different kind of failure than "couldn't reach an executor at
        // all" and shouldn't trigger trying the next executor in the list.
        callOk = true;

        bytes memory completionData;
        (hasError, completionData, , errorMessage, ) = abi.decode(
            actualOutput, (bool, bytes, bytes, string, StorageRef)
        );

        if (hasError || completionData.length == 0) {
            return (callOk, hasError, "", errorMessage);
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
