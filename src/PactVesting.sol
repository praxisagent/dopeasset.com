// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PactVesting — Linear token vesting for the PACT founder allocation
/// @notice Locks tokens and releases them linearly over 12 months. No admin, no early unlock.
/// @dev Deploy, deposit PACT, wait. That's it.

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PactVesting {

    // ──────────────────── Storage ─────────────────────────────

    /// @notice The PACT token contract
    IERC20 public immutable pactToken;

    /// @notice The beneficiary who receives vested tokens
    address public immutable beneficiary;

    /// @notice Timestamp when vesting begins (set on first deposit)
    uint256 public vestingStart;

    /// @notice Vesting duration: 365 days
    uint256 public constant VESTING_DURATION = 365 days;

    /// @notice Total tokens deposited for vesting
    uint256 public totalDeposited;

    /// @notice Total tokens already claimed
    uint256 public totalClaimed;

    // ──────────────────── Events ──────────────────────────────

    event VestingFunded(uint256 amount, uint256 vestingStart, uint256 vestingEnd);
    event TokensClaimed(uint256 amount, uint256 totalClaimed, uint256 remaining);

    // ──────────────────── Constructor ─────────────────────────

    /// @param _pactToken Address of the PACT ERC-20 contract
    /// @param _beneficiary Address that will receive vested tokens
    constructor(address _pactToken, address _beneficiary) {
        require(_pactToken != address(0), "Vesting: zero token");
        require(_beneficiary != address(0), "Vesting: zero beneficiary");
        pactToken = IERC20(_pactToken);
        beneficiary = _beneficiary;
    }

    // ──────────────────── Fund ────────────────────────────────

    /// @notice Deposit PACT to start the vesting schedule. Can only be called once.
    /// @dev Caller must have already transferred PACT to this contract.
    ///      vestingStart is set to block.timestamp on first call.
    function fund() external {
        require(vestingStart == 0, "Vesting: already funded");
        uint256 balance = pactToken.balanceOf(address(this));
        require(balance > 0, "Vesting: no tokens deposited");

        totalDeposited = balance;
        vestingStart = block.timestamp;

        emit VestingFunded(balance, vestingStart, vestingStart + VESTING_DURATION);
    }

    // ──────────────────── Claim ───────────────────────────────

    /// @notice Claim all currently vested (but unclaimed) tokens
    function claim() external {
        require(msg.sender == beneficiary, "Vesting: not beneficiary");
        require(vestingStart != 0, "Vesting: not funded");

        uint256 claimable = _vested() - totalClaimed;
        require(claimable > 0, "Vesting: nothing to claim");

        totalClaimed += claimable;
        require(pactToken.transfer(beneficiary, claimable), "Vesting: transfer failed");

        uint256 remaining = totalDeposited - totalClaimed;
        emit TokensClaimed(claimable, totalClaimed, remaining);
    }

    // ──────────────────── View ────────────────────────────────

    /// @notice Total tokens vested so far (claimed + unclaimed)
    function vested() external view returns (uint256) {
        return _vested();
    }

    /// @notice Tokens available to claim right now
    function claimable() external view returns (uint256) {
        if (vestingStart == 0) return 0;
        return _vested() - totalClaimed;
    }

    /// @notice Tokens still locked
    function locked() external view returns (uint256) {
        if (vestingStart == 0) return 0;
        return totalDeposited - _vested();
    }

    // ──────────────────── Internal ────────────────────────────

    function _vested() internal view returns (uint256) {
        if (vestingStart == 0) return 0;
        uint256 elapsed = block.timestamp - vestingStart;
        if (elapsed >= VESTING_DURATION) {
            return totalDeposited;
        }
        return (totalDeposited * elapsed) / VESTING_DURATION;
    }
}
