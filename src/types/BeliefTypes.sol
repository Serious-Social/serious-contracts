// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The side of a belief market position
enum Side {
    Support,
    Oppose
}

/// @notice Aggregate state for one side of a belief market
/// @dev Used for O(1) time-weighted signal calculation: W(t) = t * P - S
struct Pool {
    /// @notice Total principal staked on this side
    uint256 principal;
    /// @notice Sum of (deposit_amount * deposit_timestamp) for all deposits
    uint256 weightedTimestampSum;
}

/// @notice A user's staked position in a belief market
/// @dev Packed for efficient storage: slot 1 (side + withdrawn + timestamps), slots 2-3 (amounts)
struct Position {
    /// @notice The side this position supports
    Side side;
    /// @notice Whether the principal has been withdrawn
    bool withdrawn;
    /// @notice Timestamp when the position was created
    uint48 depositTimestamp;
    /// @notice Timestamp when the position becomes withdrawable
    uint48 unlockTimestamp;
    /// @notice Principal amount staked
    uint256 amount;
    /// @notice Cumulative rewards already claimed
    uint256 claimedRewards;
}

/// @notice Configuration parameters for a belief market
struct MarketParams {
    /// @notice Duration principal is locked after deposit (e.g., 30 days)
    /// @dev uint32 supports up to ~136 years in seconds
    uint32 lockPeriod;
    /// @notice Minimum stake duration before rewards start accruing (seconds)
    uint32 minRewardDuration;
    /// @notice Maximum SRP as percentage of total principal (basis points, e.g., 1000 = 10%)
    uint16 maxSrpBps;
    /// @notice Maximum reward per user as multiplier of fees paid (basis points, e.g., 20000 = 2x)
    uint16 maxUserRewardBps;
    /// @notice Base late entry fee in basis points (e.g., 50 = 0.5%)
    uint16 lateEntryFeeBaseBps;
    /// @notice Maximum late entry fee in basis points (e.g., 500 = 5%)
    uint16 lateEntryFeeMaxBps;
    /// @notice Principal amount (in token units) that adds 1 bps to late entry fee
    /// @dev For USDC (6 decimals), 1000e6 means fee increases 1 bps per $1000 staked
    uint64 lateEntryFeeScale;
    /// @notice Author challenge premium in basis points (e.g., 200 = 2%)
    uint16 authorPremiumBps;
    /// @notice Whether to deposit principal into Aave for yield-bearing escrow
    /// @dev When enabled, yield is skimmed to fund the SRP. Disabled by default.
    bool yieldBearingEscrow;
}

/// @notice State snapshot for view functions
struct MarketState {
    /// @notice Current belief curve value (0 to 1e18, where 1e18 = 100% support)
    uint256 belief;
    /// @notice Time-weighted signal for support side
    uint256 supportWeight;
    /// @notice Time-weighted signal for oppose side
    uint256 opposeWeight;
    /// @notice Total principal in support pool
    uint256 supportPrincipal;
    /// @notice Total principal in oppose pool
    uint256 opposePrincipal;
    /// @notice Current balance in Signal Reward Pool
    uint256 srpBalance;
}

/// @notice Checkpoint for discrete reward distribution
/// @dev Created when SRP receives funds; positions claim proportional share based on weight
struct RewardCheckpoint {
    /// @notice Reward amount added at this checkpoint
    uint256 amount;
    /// @notice Timestamp when checkpoint was created
    uint48 timestamp;
    /// @notice Total weight across all active positions at checkpoint time
    uint256 totalWeight;
}
