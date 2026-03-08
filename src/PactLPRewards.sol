// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PactLPRewards — Incentivize PACT/ETH liquidity providers
/// @notice Stake LP tokens, earn PACT rewards. Optional time-locks for bonus multipliers.
/// @dev Based on the Synthetix StakingRewards pattern, adapted for lock multipliers.
///      No admin keys, no upgradability. Rewarder is set once at construction.

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PactLPRewards {

    // ──────────────────── Constants ────────────────────────────

    /// @notice Lock tiers and their multipliers (basis points, 10000 = 1x)
    uint256 public constant MULTIPLIER_NONE   = 10000; // 1.0x — no lock
    uint256 public constant MULTIPLIER_3MO    = 15000; // 1.5x — 3 month lock
    uint256 public constant MULTIPLIER_6MO    = 20000; // 2.0x — 6 month lock

    uint256 public constant LOCK_NONE = 0;
    uint256 public constant LOCK_3MO  = 90 days;
    uint256 public constant LOCK_6MO  = 180 days;

    uint256 private constant PRECISION = 1e18;

    // ──────────────────── Storage ──────────────────────────────

    /// @notice The PACT token (reward)
    IERC20 public immutable pactToken;

    /// @notice The LP token (stake)
    IERC20 public immutable lpToken;

    /// @notice Address that can fund reward periods
    address public immutable rewarder;

    /// @notice Reward rate: PACT per second
    uint256 public rewardRate;

    /// @notice Timestamp when current reward period ends
    uint256 public periodEnd;

    /// @notice Last time rewards were updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated rewards per unit of weighted stake
    uint256 public rewardPerWeightedToken;

    /// @notice Total weighted stake (LP amount * multiplier / 10000)
    uint256 public totalWeightedSupply;

    /// @notice Total raw LP tokens staked
    uint256 public totalStaked;

    struct Stake {
        uint256 amount;           // Raw LP tokens
        uint256 weightedAmount;   // amount * multiplier / 10000
        uint256 lockEnd;          // Timestamp when lock expires (0 = no lock)
        uint256 rewardSnapshot;   // rewardPerWeightedToken at last update
        uint256 pendingRewards;   // Accumulated unclaimed rewards
    }

    /// @notice Each address can have one active stake position
    mapping(address => Stake) public stakes;

    // ──────────────────── Events ──────────────────────────────

    event RewardsFunded(uint256 amount, uint256 rewardRate, uint256 periodEnd);
    event Staked(address indexed user, uint256 amount, uint256 lockDuration, uint256 multiplier);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);

    // ──────────────────── Constructor ─────────────────────────

    /// @param _pactToken The PACT ERC-20 contract
    /// @param _lpToken   The LP token contract (e.g. Camelot PACT/ETH pair)
    /// @param _rewarder  Address authorized to fund reward periods
    constructor(address _pactToken, address _lpToken, address _rewarder) {
        require(_pactToken != address(0), "LPRewards: zero pact");
        require(_lpToken != address(0), "LPRewards: zero lp");
        require(_rewarder != address(0), "LPRewards: zero rewarder");
        pactToken = IERC20(_pactToken);
        lpToken = IERC20(_lpToken);
        rewarder = _rewarder;
    }

    // ──────────────────── Fund ────────────────────────────────

    /// @notice Fund a reward period. Caller must have transferred PACT to this contract first.
    /// @param amount   PACT tokens to distribute as rewards
    /// @param duration How long the reward period lasts (in seconds)
    function fund(uint256 amount, uint256 duration) external {
        require(msg.sender == rewarder, "LPRewards: not rewarder");
        require(amount > 0, "LPRewards: zero amount");
        require(duration > 0, "LPRewards: zero duration");

        _updateGlobal();

        // If there's an ongoing period, roll leftover into the new period
        uint256 leftover = 0;
        if (block.timestamp < periodEnd) {
            leftover = rewardRate * (periodEnd - block.timestamp);
        }

        uint256 total = amount + leftover;
        rewardRate = total / duration;
        require(rewardRate > 0, "LPRewards: rate too low");

        lastUpdateTime = block.timestamp;
        periodEnd = block.timestamp + duration;

        // Pull tokens from rewarder
        require(pactToken.transferFrom(msg.sender, address(this), amount), "LPRewards: fund transfer failed");

        emit RewardsFunded(amount, rewardRate, periodEnd);
    }

    // ──────────────────── Stake ───────────────────────────────

    /// @notice Stake LP tokens with an optional lock for bonus rewards
    /// @param amount       LP tokens to stake
    /// @param lockDuration One of: 0, 90 days, 180 days
    function stake(uint256 amount, uint256 lockDuration) external {
        require(amount > 0, "LPRewards: zero stake");
        require(
            lockDuration == LOCK_NONE || lockDuration == LOCK_3MO || lockDuration == LOCK_6MO,
            "LPRewards: invalid lock"
        );

        _updateGlobal();

        Stake storage s = stakes[msg.sender];

        // Settle any existing rewards
        if (s.weightedAmount > 0) {
            s.pendingRewards += _earned(s);
        }

        // If user already has a stake, they can add more but lock must be >= existing
        if (s.amount > 0) {
            uint256 newLockEnd = block.timestamp + lockDuration;
            require(newLockEnd >= s.lockEnd, "LPRewards: cannot shorten lock");
            if (lockDuration > 0) {
                s.lockEnd = newLockEnd;
            }
        } else if (lockDuration > 0) {
            s.lockEnd = block.timestamp + lockDuration;
        }

        uint256 multiplier = _multiplier(lockDuration);
        uint256 newWeighted = (s.amount + amount) * multiplier / 10000;

        // Update totals
        totalWeightedSupply = totalWeightedSupply - s.weightedAmount + newWeighted;
        totalStaked = totalStaked - s.amount + (s.amount + amount);

        s.amount += amount;
        s.weightedAmount = newWeighted;
        s.rewardSnapshot = rewardPerWeightedToken;

        require(lpToken.transferFrom(msg.sender, address(this), amount), "LPRewards: stake transfer failed");

        emit Staked(msg.sender, amount, lockDuration, multiplier);
    }

    // ──────────────────── Withdraw ────────────────────────────

    /// @notice Withdraw staked LP tokens. Must wait for lock to expire.
    /// @param amount LP tokens to withdraw
    function withdraw(uint256 amount) external {
        Stake storage s = stakes[msg.sender];
        require(amount > 0, "LPRewards: zero withdraw");
        require(s.amount >= amount, "LPRewards: insufficient stake");
        require(block.timestamp >= s.lockEnd, "LPRewards: still locked");

        _updateGlobal();

        // Settle rewards before changing balance
        s.pendingRewards += _earned(s);

        uint256 newAmount = s.amount - amount;
        uint256 newWeighted;
        if (newAmount > 0) {
            // Keep the same multiplier ratio
            newWeighted = s.weightedAmount * newAmount / s.amount;
        }

        totalWeightedSupply = totalWeightedSupply - s.weightedAmount + newWeighted;
        totalStaked -= amount;

        s.amount = newAmount;
        s.weightedAmount = newWeighted;
        s.rewardSnapshot = rewardPerWeightedToken;

        require(lpToken.transfer(msg.sender, amount), "LPRewards: withdraw failed");

        emit Withdrawn(msg.sender, amount);
    }

    // ──────────────────── Claim ───────────────────────────────

    /// @notice Claim accumulated PACT rewards. Can claim anytime, even while locked.
    function claim() external {
        _updateGlobal();

        Stake storage s = stakes[msg.sender];
        uint256 reward = s.pendingRewards + _earned(s);
        require(reward > 0, "LPRewards: nothing to claim");

        s.pendingRewards = 0;
        s.rewardSnapshot = rewardPerWeightedToken;

        require(pactToken.transfer(msg.sender, reward), "LPRewards: claim failed");

        emit RewardClaimed(msg.sender, reward);
    }

    // ──────────────────── View ────────────────────────────────

    /// @notice PACT rewards currently claimable by a user
    function claimable(address user) external view returns (uint256) {
        Stake storage s = stakes[user];
        if (s.weightedAmount == 0) return s.pendingRewards;

        uint256 projected = rewardPerWeightedToken;
        if (totalWeightedSupply > 0) {
            uint256 elapsed = _min(block.timestamp, periodEnd) - lastUpdateTime;
            projected += (elapsed * rewardRate * PRECISION) / totalWeightedSupply;
        }

        return s.pendingRewards + (s.weightedAmount * (projected - s.rewardSnapshot)) / PRECISION;
    }

    /// @notice Seconds until a user's lock expires (0 if unlocked)
    function lockRemaining(address user) external view returns (uint256) {
        if (block.timestamp >= stakes[user].lockEnd) return 0;
        return stakes[user].lockEnd - block.timestamp;
    }

    // ──────────────────── Internal ────────────────────────────

    function _updateGlobal() internal {
        if (totalWeightedSupply > 0) {
            uint256 elapsed = _min(block.timestamp, periodEnd) - lastUpdateTime;
            rewardPerWeightedToken += (elapsed * rewardRate * PRECISION) / totalWeightedSupply;
        }
        lastUpdateTime = _min(block.timestamp, periodEnd);
    }

    function _earned(Stake storage s) internal view returns (uint256) {
        return (s.weightedAmount * (rewardPerWeightedToken - s.rewardSnapshot)) / PRECISION;
    }

    function _multiplier(uint256 lockDuration) internal pure returns (uint256) {
        if (lockDuration == LOCK_6MO) return MULTIPLIER_6MO;
        if (lockDuration == LOCK_3MO) return MULTIPLIER_3MO;
        return MULTIPLIER_NONE;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
