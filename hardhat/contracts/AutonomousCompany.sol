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
//  Pattern mirrors the deployed & proven SovereignRepAgent / AIJudge
//  contracts: direct interface calls to precompiles, try/catch fallback,
//  Scheduler re-arms itself inside wakeUp().
// ================================================================

interface ILLMPrecompile {
    struct Message {
        string role;    // "system" | "user" | "assistant"
        string content;
    }
    struct LLMRequest {
        Message[] messages;
        uint32 maxTokens;
        bool stream;
    }
    function complete(LLMRequest calldata req) external returns (string memory text);
}

interface IScheduler {
    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency
    ) external returns (uint256 callId);
    function cancel(uint256 callId) external;
}

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
}

contract AutonomousCompany {
    address internal constant LLM = 0x0000000000000000000000000000000000000802;
    address internal constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address internal constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;

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

        // Ritual's Scheduler pulls execution fees from RitualWallet, not from
        // this contract's plain balance. Fund it before the first schedule call.
        uint256 depositAmount = SCHEDULER_FEE_DEPOSIT;
        if (address(this).balance < depositAmount) {
            depositAmount = address(this).balance;
        }
        if (depositAmount > 0) {
            try IRitualWallet(RITUAL_WALLET).deposit{value: depositAmount}(SCHEDULER_LOCK_DURATION) {
                // deposit ok
            } catch {
                revert DepositFailed();
            }
        }

        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, uint256(0));
        try IScheduler(SCHEDULER).schedule(data, 300000, 1, WAKE_INTERVAL) returns (uint256 id) {
            scheduleId = id;
        } catch {
            revert ScheduleFailed();
        }

        emit CompanyStarted(block.number);
    }

    function wakeUp(uint256) external {
        if (msg.sender != SCHEDULER) revert OnlyScheduler();
        if (!running) return;

        wakeCount++;
        lastWakeBlock = block.number;
        lastHeartbeat = _heartbeatCheck();

        // Re-arm — this is what makes the company sovereign: nobody
        // needs to call it again, it schedules its own next tick.
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
        // First param after the selector must be a placeholder executionIndex —
        // the Scheduler overwrites it with the real value at execution time.
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, uint256(0));
        return IScheduler(SCHEDULER).schedule(data, 300000, 1, delay);
    }

    // Lightweight self-check the LLM performs every heartbeat —
    // proves the loop is alive and reasoning, independent of paid requests.
    function _heartbeatCheck() internal returns (string memory) {
        ILLMPrecompile.Message[] memory msgs = new ILLMPrecompile.Message[](2);
        msgs[0] = ILLMPrecompile.Message({
            role: "system",
            content: systemPrompt
        });
        msgs[1] = ILLMPrecompile.Message({
            role: "user",
            content: "Routine heartbeat check. In under 15 words, state your operating status and readiness for new requests."
        });

        ILLMPrecompile.LLMRequest memory req = ILLMPrecompile.LLMRequest({
            messages: msgs,
            maxTokens: 60,
            stream: false
        });

        try ILLMPrecompile(LLM).complete(req) returns (string memory result) {
            return result;
        } catch {
            return "heartbeat ok (LLM unavailable this tick)";
        }
    }

    // ══════════════════════════════════════════════════════════
    //  PAID SERVICE — any caller pays feePerRequest to use the company
    // ══════════════════════════════════════════════════════════

    function requestService(string calldata input) external payable returns (string memory output) {
        if (msg.value < feePerRequest) revert InsufficientFee();
        totalRevenue += msg.value;
        requestCount++;

        ILLMPrecompile.Message[] memory msgs = new ILLMPrecompile.Message[](2);
        msgs[0] = ILLMPrecompile.Message({
            role: "system",
            content: systemPrompt
        });
        msgs[1] = ILLMPrecompile.Message({
            role: "user",
            content: input
        });

        ILLMPrecompile.LLMRequest memory req = ILLMPrecompile.LLMRequest({
            messages: msgs,
            maxTokens: 200,
            stream: false
        });

        try ILLMPrecompile(LLM).complete(req) returns (string memory result) {
            output = result;
        } catch {
            output = "service temporarily unavailable, fee refund not automatic - contact owner";
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
