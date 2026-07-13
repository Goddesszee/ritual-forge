// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ================================================================
//  DCABot — a self-waking agent that dollar-cost-averages RITUAL
//  into FORGE on a recurring schedule, entirely on its own.
//
//  Deliberately built WITHOUT touching the LLM precompile or
//  TEEServiceRegistry at all. Every piece here — Scheduler's
//  schedule() signature and gas parameters, RitualWallet's deposit
//  interface, the resilient non-reverting reschedule pattern — is
//  copied from AutonomousCompany.sol exactly as proven working in
//  production, not re-guessed. The only new logic here is "on wake,
//  swap a fixed amount" — plain Solidity, no precompiles, no TEE
//  executor dependency, so it isn't exposed to the executor-registry
//  outage that affects the LLM-calling path.
// ================================================================

interface IScheduler {
    // Same 10-param signature confirmed against Ritual's own official
    // documented example. See AutonomousCompany.sol for the full history
    // of why this exact signature and these exact gas/fee values matter.
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

interface IRitualForgeSwap {
    function swapRitualForForge(uint256 minForgeOut) external payable returns (uint256 forgeOut);
    function quoteRitualToForge(uint256 ritualIn) external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract DCABot {
    address internal constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;
    address internal constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;

    uint32 public constant WAKE_INTERVAL = 500; // ~3 min on Ritual testnet, same cadence as AutonomousCompany
    uint256 public constant SCHEDULER_FEE_DEPOSIT = 0.06 ether; // measured-correct value from today's investigation
    uint256 public constant SCHEDULER_LOCK_DURATION = 50000;
    uint256 public constant WAKE_TOPUP_AMOUNT = 0.0005 ether;

    address public immutable owner;
    address public immutable swapAddress;
    address public immutable forgeToken;
    uint256 public immutable swapAmountPerCycle; // RITUAL spent each wake

    bool public running;
    uint256 public scheduleId;
    uint256 public cycleCount;
    uint256 public totalRitualSpent;
    uint256 public totalForgeReceived;
    string public lastResult;

    event BotStarted(uint256 atBlock);
    event SwapExecuted(uint256 indexed cycle, uint256 ritualIn, uint256 forgeOut, uint256 atBlock);
    event SwapSkipped(uint256 indexed cycle, string reason);
    event RescheduleFailed(uint256 atBlock);
    event Kicked(uint256 newScheduleId, uint256 atBlock);
    event Withdrawn(address indexed to, uint256 ritualAmount, uint256 forgeAmount);

    error OnlyOwner();
    error OnlyScheduler();
    error AlreadyRunning();
    error NotRunning();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address _owner, address _swapAddress, address _forgeToken, uint256 _swapAmountPerCycle) payable {
        owner = _owner;
        swapAddress = _swapAddress;
        forgeToken = _forgeToken;
        swapAmountPerCycle = _swapAmountPerCycle;
    }

    receive() external payable {}

    /// @notice Funds RitualWallet and registers the first wake-up. Reverts
    ///         on failure — same as AutonomousCompany, we want to know
    ///         immediately if starting didn't work.
    function start() external onlyOwner {
        if (running) revert AlreadyRunning();
        running = true;
        _fundWallet(SCHEDULER_FEE_DEPOSIT);
        (bool ok, uint256 callId) = _scheduleWakeup(WAKE_INTERVAL);
        require(ok, "initial schedule failed");
        scheduleId = callId;
        emit BotStarted(block.number);
    }

    /// @notice Recovery valve, same pattern as AutonomousCompany.kick().
    function kick() external onlyOwner {
        if (!running) revert NotRunning();
        _fundWallet(SCHEDULER_FEE_DEPOSIT);
        (bool ok, uint256 callId) = _scheduleWakeup(WAKE_INTERVAL);
        require(ok, "kick: schedule still failing");
        scheduleId = callId;
        emit Kicked(callId, block.number);
    }

    function stop() external onlyOwner {
        running = false;
        if (scheduleId != 0) {
            IScheduler(SCHEDULER).cancel(scheduleId);
        }
    }

    /// @notice Called by Scheduler on every cycle. Swaps a fixed amount of
    ///         RITUAL into FORGE, then re-funds and re-schedules itself —
    ///         same resilience pattern as AutonomousCompany.wakeUp(): a
    ///         failure here doesn't revert the whole call and erase the
    ///         cycle counter, it's caught and recorded instead.
    function wakeUp(uint256) external {
        if (msg.sender != SCHEDULER) revert OnlyScheduler();
        if (!running) return;

        cycleCount++;

        if (address(this).balance >= swapAmountPerCycle) {
            try IRitualForgeSwap(swapAddress).swapRitualForForge{value: swapAmountPerCycle}(0) returns (uint256 forgeOut) {
                totalRitualSpent += swapAmountPerCycle;
                totalForgeReceived += forgeOut;
                lastResult = "swap ok";
                emit SwapExecuted(cycleCount, swapAmountPerCycle, forgeOut, block.number);
            } catch Error(string memory reason) {
                lastResult = string(abi.encodePacked("swap reverted: ", reason));
                emit SwapSkipped(cycleCount, lastResult);
            } catch {
                lastResult = "swap reverted (no reason)";
                emit SwapSkipped(cycleCount, lastResult);
            }
        } else {
            lastResult = "skipped: insufficient RITUAL balance for this cycle";
            emit SwapSkipped(cycleCount, lastResult);
        }

        _tryTopUpWallet(WAKE_TOPUP_AMOUNT);

        (bool schedOk, uint256 callId) = _scheduleWakeup(WAKE_INTERVAL);
        if (schedOk) {
            scheduleId = callId;
        } else {
            scheduleId = 0;
            emit RescheduleFailed(block.number);
        }
    }

    /// @notice Owner can withdraw remaining RITUAL and accumulated FORGE.
    function withdraw() external onlyOwner {
        uint256 ritualBal = address(this).balance;
        uint256 forgeBal = IERC20Min(forgeToken).balanceOf(address(this));
        if (ritualBal > 0) {
            (bool ok, ) = payable(owner).call{value: ritualBal}("");
            require(ok, "ritual withdraw failed");
        }
        if (forgeBal > 0) {
            require(IERC20Min(forgeToken).transfer(owner, forgeBal), "forge withdraw failed");
        }
        emit Withdrawn(owner, ritualBal, forgeBal);
    }

    function _fundWallet(uint256 amount) internal {
        uint256 depositAmount = amount;
        if (address(this).balance < depositAmount) {
            depositAmount = address(this).balance;
        }
        if (depositAmount > 0) {
            (bool ok, bytes memory result) = RITUAL_WALLET.call{value: depositAmount}(
                abi.encodeWithSelector(IRitualWallet.deposit.selector, SCHEDULER_LOCK_DURATION)
            );
            if (!ok) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }

    function _tryTopUpWallet(uint256 amount) internal returns (bool) {
        uint256 depositAmount = amount;
        if (address(this).balance < depositAmount) {
            depositAmount = address(this).balance;
        }
        if (depositAmount == 0) return true;
        (bool ok, ) = RITUAL_WALLET.call{value: depositAmount}(
            abi.encodeWithSelector(IRitualWallet.deposit.selector, SCHEDULER_LOCK_DURATION)
        );
        return ok;
    }

    function _scheduleWakeup(uint32 delay) internal returns (bool, uint256) {
        bytes memory data = abi.encodeWithSelector(this.wakeUp.selector, uint256(0));

        (bool ok, bytes memory result) = SCHEDULER.call(
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
        if (!ok) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }
}
