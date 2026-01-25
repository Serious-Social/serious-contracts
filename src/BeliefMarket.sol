// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBeliefMarket} from "./interfaces/IBeliefMarket.sol";
import {Side, Pool, Position, MarketParams, MarketState} from "./types/BeliefTypes.sol";

/// @title BeliefMarket
/// @notice A market where users stake USDC to signal belief (support or oppose) on claims
/// @dev Implements time-weighted signal mechanics where patience is rewarded over speed
/// Uses EIP-1167 minimal proxy pattern for gas-efficient deployment
contract BeliefMarket is IBeliefMarket {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator (100%)
    uint256 private constant BPS = 10_000;

    /// @notice Precision for belief calculation (1e18 = 100%)
    uint256 private constant PRECISION = 1e18;

    /// @notice High precision for reward accumulators (1e27)
    uint256 private constant RAY = 1e27;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether the contract has been initialized
    bool private _initialized;

    /// @notice The post ID this market is associated with
    bytes32 public postId;

    /// @notice The factory that created this market
    address public factory;

    /// @notice The USDC token used for staking
    IERC20 public usdc;

    /// @notice Market configuration parameters
    MarketParams public params;

    /// @notice Support side pool state
    Pool public supportPool;

    /// @notice Oppose side pool state
    Pool public opposePool;

    /// @notice Balance in the Signal Reward Pool
    uint256 public srpBalance;

    /// @notice Next position ID to assign
    uint256 private _nextPositionId;

    /// @notice Position data by ID
    mapping(uint256 => Position) private _positions;

    /// @notice Position owner by ID
    mapping(uint256 => address) private _positionOwners;

    /// @notice User's position IDs
    mapping(address => uint256[]) private _userPositions;

    /// @notice Fees paid by each position (for max reward cap calculation)
    mapping(uint256 => uint256) private _positionFeesPaid;

    /*//////////////////////////////////////////////////////////////
                        REWARD ACCUMULATORS (O(1))
    //////////////////////////////////////////////////////////////*/

    /// @notice Global accumulator: Σ (reward × timestamp / totalWeight)
    /// @dev Used with rewardPerPrincipalPerTime for O(1) reward calculation
    uint256 public rewardPerPrincipalTime;

    /// @notice Global accumulator: Σ (reward / totalWeight)
    /// @dev Combined with depositTimestamp to calculate time-weighted rewards
    uint256 public rewardPerPrincipalPerTime;

    /// @notice Per-position snapshot of rewardPerPrincipalTime at deposit/claim
    mapping(uint256 => uint256) public positionRewardPerPrincipalTimePaid;

    /// @notice Per-position snapshot of rewardPerPrincipalPerTime at deposit/claim
    mapping(uint256 => uint256) public positionRewardPerPrincipalPerTimePaid;

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the market (called by factory via clone pattern)
    /// @param postId_ The post ID this market tracks
    /// @param usdc_ The USDC token address
    /// @param params_ Market configuration parameters
    /// @param author_ The post author (for initial commitment)
    /// @param initialCommitment_ Author's initial stake amount (0 if none)
    function initialize(
        bytes32 postId_,
        address usdc_,
        MarketParams calldata params_,
        address author_,
        uint256 initialCommitment_
    ) external {
        require(!_initialized, "Already initialized");
        _initialized = true;

        postId = postId_;
        factory = msg.sender;
        usdc = IERC20(usdc_);
        params = params_;

        // Start position IDs at 1 (0 indicates non-existent)
        _nextPositionId = 1;

        // Handle author's initial commitment if provided
        if (initialCommitment_ > 0 && author_ != address(0)) {
            _commitAsAuthor(author_, initialCommitment_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBeliefMarket
    function commitSupport(uint256 amount) external returns (uint256 positionId) {
        return _commit(Side.Support, amount);
    }

    /// @inheritdoc IBeliefMarket
    function commitOppose(uint256 amount) external returns (uint256 positionId) {
        return _commit(Side.Oppose, amount);
    }

    /// @inheritdoc IBeliefMarket
    function withdraw(uint256 positionId) external {
        if (_positionOwners[positionId] == address(0)) revert PositionNotFound();
        if (_positionOwners[positionId] != msg.sender) revert NotPositionOwner();

        Position storage pos = _positions[positionId];
        if (pos.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < pos.unlockTimestamp) revert PositionLocked();

        // Auto-claim any pending rewards before withdrawal to prevent trapped funds
        uint256 rewardsClaimed = _claimRewardsInternal(positionId, pos);

        pos.withdrawn = true;

        // Update pool state
        Pool storage pool = pos.side == Side.Support ? supportPool : opposePool;
        pool.principal -= pos.amount;
        pool.weightedTimestampSum -= pos.amount * pos.depositTimestamp;

        // Transfer principal back to user
        usdc.safeTransfer(msg.sender, pos.amount);

        emit Withdrawn(positionId, msg.sender, pos.amount);
        if (rewardsClaimed > 0) {
            emit RewardsClaimed(positionId, msg.sender, rewardsClaimed);
        }
    }

    /// @inheritdoc IBeliefMarket
    function claimRewards(uint256 positionId) external returns (uint256 amount) {
        if (_positionOwners[positionId] == address(0)) revert PositionNotFound();
        if (_positionOwners[positionId] != msg.sender) revert NotPositionOwner();

        Position storage pos = _positions[positionId];

        // Check minRewardDuration (external claims enforce this; internal claims from withdraw skip it)
        if (block.timestamp < pos.depositTimestamp + params.minRewardDuration) {
            revert MinRewardDurationNotMet();
        }

        uint256 claimable = _claimRewardsInternal(positionId, pos);
        if (claimable == 0) revert NoRewardsToClaim();

        emit RewardsClaimed(positionId, msg.sender, claimable);
        return claimable;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBeliefMarket
    function belief() external view returns (uint256) {
        uint256 wSupport = _getWeight(Side.Support);
        uint256 wOppose = _getWeight(Side.Oppose);

        // If both sides have zero weight, return 50%
        if (wSupport == 0 && wOppose == 0) {
            return PRECISION / 2;
        }

        return (wSupport * PRECISION) / (wSupport + wOppose);
    }

    /// @inheritdoc IBeliefMarket
    function getWeight(Side side) external view returns (uint256 weight) {
        return _getWeight(side);
    }

    /// @inheritdoc IBeliefMarket
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        if (_positionOwners[positionId] == address(0)) revert PositionNotFound();
        return _positions[positionId];
    }

    /// @inheritdoc IBeliefMarket
    function pendingRewards(uint256 positionId) external view returns (uint256 amount) {
        if (_positionOwners[positionId] == address(0)) revert PositionNotFound();

        Position memory pos = _positions[positionId];

        // Check minRewardDuration
        if (block.timestamp < pos.depositTimestamp + params.minRewardDuration) {
            return 0;
        }

        uint256 pending = _calculatePendingRewards(positionId);

        // Apply max user reward cap
        uint256 maxReward = _calculateMaxUserReward(positionId);
        return _min(pending, maxReward - pos.claimedRewards);
    }

    /// @inheritdoc IBeliefMarket
    function getMarketState() external view returns (MarketState memory state) {
        uint256 wSupport = _getWeight(Side.Support);
        uint256 wOppose = _getWeight(Side.Oppose);

        uint256 beliefValue;
        if (wSupport == 0 && wOppose == 0) {
            beliefValue = PRECISION / 2;
        } else {
            beliefValue = (wSupport * PRECISION) / (wSupport + wOppose);
        }

        return MarketState({
            belief: beliefValue,
            supportWeight: wSupport,
            opposeWeight: wOppose,
            supportPrincipal: supportPool.principal,
            opposePrincipal: opposePool.principal,
            srpBalance: srpBalance
        });
    }

    /// @inheritdoc IBeliefMarket
    function getMarketParams() external view returns (MarketParams memory) {
        return params;
    }

    /// @inheritdoc IBeliefMarket
    function getUserPositions(address user) external view returns (uint256[] memory positionIds) {
        return _userPositions[user];
    }

    /// @notice Get the current late entry fee in basis points
    /// @return feeBps The current fee (scales with total principal staked)
    function getCurrentEntryFeeBps() external view returns (uint256 feeBps) {
        uint256 totalPrincipal = supportPool.principal + opposePool.principal;
        if (totalPrincipal == 0) {
            return 0; // First staker pays no late entry fee
        }
        return _calculateLateEntryFeeBps(totalPrincipal);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal commit logic for both sides
    function _commit(Side side, uint256 amount) internal returns (uint256 positionId) {
        if (amount < params.minStake || amount > params.maxStake) revert StakeOutOfRange();

        // Transfer USDC from sender
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 netAmount = amount;
        uint256 fee = 0;

        // Apply late entry fee if market is active (has existing stakes)
        uint256 totalPrincipal = supportPool.principal + opposePool.principal;
        if (totalPrincipal > 0) {
            uint256 feeBps = _calculateLateEntryFeeBps(totalPrincipal);
            fee = (amount * feeBps) / BPS;
            // _addToSrp may cap the fee due to maxSrpBps; excess stays with user as principal
            uint256 actualFee = _addToSrp(fee, "late_entry");
            netAmount = amount - actualFee;
            fee = actualFee; // Update fee to actual amount for _positionFeesPaid
        }

        // Update pool state
        Pool storage pool = side == Side.Support ? supportPool : opposePool;
        pool.principal += netAmount;
        pool.weightedTimestampSum += netAmount * block.timestamp;

        // Create position
        positionId = _nextPositionId++;
        uint48 depositTime = uint48(block.timestamp);
        uint48 unlockTime = depositTime + params.lockPeriod;

        _positions[positionId] = Position({
            side: side,
            withdrawn: false,
            depositTimestamp: depositTime,
            unlockTimestamp: unlockTime,
            amount: netAmount,
            claimedRewards: 0
        });

        _positionOwners[positionId] = msg.sender;
        _userPositions[msg.sender].push(positionId);
        _positionFeesPaid[positionId] = fee;

        // Snapshot reward accumulators for O(1) reward calculation
        positionRewardPerPrincipalTimePaid[positionId] = rewardPerPrincipalTime;
        positionRewardPerPrincipalPerTimePaid[positionId] = rewardPerPrincipalPerTime;

        emit Committed(positionId, msg.sender, side, netAmount, unlockTime);
    }

    /// @notice Handle author's initial commitment (no late entry fee)
    /// @dev USDC is already transferred to this contract by the factory
    function _commitAsAuthor(address author, uint256 amount) internal {
        if (amount < params.minStake || amount > params.maxStake) revert StakeOutOfRange();
        // Note: USDC already transferred by factory before initialize() is called

        // Author pays premium to SRP
        uint256 premium = (amount * params.authorPremiumBps) / BPS;
        // _addToSrp may cap the premium due to maxSrpBps; excess stays with author as principal
        uint256 actualPremium = _addToSrp(premium, "author_premium");
        uint256 netAmount = amount - actualPremium;

        // Update support pool
        supportPool.principal += netAmount;
        supportPool.weightedTimestampSum += netAmount * block.timestamp;

        // Create position
        uint256 positionId = _nextPositionId++;
        uint48 depositTime = uint48(block.timestamp);
        uint48 unlockTime = depositTime + params.lockPeriod;

        _positions[positionId] = Position({
            side: Side.Support,
            withdrawn: false,
            depositTimestamp: depositTime,
            unlockTimestamp: unlockTime,
            amount: netAmount,
            claimedRewards: 0
        });

        _positionOwners[positionId] = author;
        _userPositions[author].push(positionId);
        _positionFeesPaid[positionId] = actualPremium;

        // Snapshot reward accumulators for O(1) reward calculation
        positionRewardPerPrincipalTimePaid[positionId] = rewardPerPrincipalTime;
        positionRewardPerPrincipalPerTimePaid[positionId] = rewardPerPrincipalPerTime;

        emit Committed(positionId, author, Side.Support, netAmount, unlockTime);
    }

    /// @notice Internal claim logic used by both claimRewards() and withdraw()
    /// @dev Does not check minRewardDuration - caller must handle that if needed
    /// @param positionId The position to claim rewards for
    /// @param pos Storage pointer to the position
    /// @return claimable Amount of rewards claimed (0 if none)
    function _claimRewardsInternal(uint256 positionId, Position storage pos) internal returns (uint256 claimable) {
        // Skip if minRewardDuration not met (rewards are 0 anyway per pendingRewards logic)
        if (block.timestamp < pos.depositTimestamp + params.minRewardDuration) {
            return 0;
        }

        uint256 pending = _calculatePendingRewards(positionId);
        if (pending == 0) return 0;

        // Apply max user reward cap
        uint256 maxReward = _calculateMaxUserReward(positionId);
        claimable = _min(pending, maxReward - pos.claimedRewards);

        if (claimable == 0) return 0;

        // Update state - snapshot current accumulators
        positionRewardPerPrincipalTimePaid[positionId] = rewardPerPrincipalTime;
        positionRewardPerPrincipalPerTimePaid[positionId] = rewardPerPrincipalPerTime;
        pos.claimedRewards += claimable;
        srpBalance -= claimable;

        // Transfer rewards
        usdc.safeTransfer(msg.sender, claimable);

        return claimable;
    }

    /// @notice Add funds to SRP and update reward accumulators
    /// @dev Uses Synthetix-style O(1) accumulator pattern adapted for time-weighted stakes
    /// @dev Enforces maxSrpBps cap - returns actual amount added (may be less than requested)
    /// @param amount The amount to add to SRP
    /// @param source Description of the fee source (for events)
    /// @return actualAmount The actual amount added (may be capped)
    function _addToSrp(uint256 amount, string memory source) internal returns (uint256 actualAmount) {
        // Enforce maxSrpBps cap: SRP cannot exceed maxSrpBps of total principal
        uint256 totalPrincipal = supportPool.principal + opposePool.principal;

        // If no principal yet (first deposit), allow the fee without cap
        // The cap is meaningless when there's nothing to cap against
        if (totalPrincipal == 0) {
            actualAmount = amount;
        } else {
            uint256 maxSrp = (totalPrincipal * params.maxSrpBps) / BPS;

            // Cap amount to not exceed maxSrp
            if (srpBalance >= maxSrp) {
                actualAmount = 0;
            } else if (srpBalance + amount > maxSrp) {
                actualAmount = maxSrp - srpBalance;
            } else {
                actualAmount = amount;
            }
        }

        if (actualAmount > 0) {
            srpBalance += actualAmount;

            uint256 totalWeight = _getTotalWeight();
            if (totalWeight > 0) {
                // Update accumulators for O(1) reward calculation
                // rewardPerPrincipalTime += (amount × timestamp × RAY) / totalWeight
                // rewardPerPrincipalPerTime += (amount × RAY) / totalWeight
                rewardPerPrincipalTime += (actualAmount * block.timestamp * RAY) / totalWeight;
                rewardPerPrincipalPerTime += (actualAmount * RAY) / totalWeight;
            }
            // If no weight yet, funds stay in SRP for future distribution

            emit SrpFunded(actualAmount, source);
        }

        return actualAmount;
    }

    /// @notice Calculate time-weighted signal for a side
    function _getWeight(Side side) internal view returns (uint256) {
        Pool storage pool = side == Side.Support ? supportPool : opposePool;

        // W(t) = t * P - S
        uint256 timeWeightedPrincipal = block.timestamp * pool.principal;

        // Avoid underflow (shouldn't happen in normal operation)
        if (timeWeightedPrincipal < pool.weightedTimestampSum) {
            return 0;
        }

        return timeWeightedPrincipal - pool.weightedTimestampSum;
    }

    /// @notice Get total weight across both sides
    function _getTotalWeight() internal view returns (uint256) {
        return _getWeight(Side.Support) + _getWeight(Side.Oppose);
    }

    /// @notice Calculate pending rewards for a position in O(1)
    /// @dev Uses dual accumulator pattern: pending = amount × (ΔA - depositTime × ΔB)
    /// where A = Σ(reward × time / weight) and B = Σ(reward / weight)
    function _calculatePendingRewards(uint256 positionId) internal view returns (uint256) {
        Position memory pos = _positions[positionId];

        // Withdrawn positions forfeit unclaimed rewards
        if (pos.withdrawn) return 0;

        // Calculate deltas since position was created/last claimed
        uint256 deltaA = rewardPerPrincipalTime - positionRewardPerPrincipalTimePaid[positionId];
        uint256 deltaB = rewardPerPrincipalPerTime - positionRewardPerPrincipalPerTimePaid[positionId];

        // No rewards accumulated
        if (deltaA == 0 && deltaB == 0) return 0;

        // pending = amount × (deltaA - depositTime × deltaB) / RAY
        // This equals: amount × Σ[reward × (checkpointTime - depositTime) / totalWeight]
        uint256 timeWeightedDelta = deltaA - (uint256(pos.depositTimestamp) * deltaB);

        return (pos.amount * timeWeightedDelta) / RAY;
    }

    /// @notice Calculate max reward for a position based on fees paid
    /// @dev If position paid no fees (first staker/author), cap at maxUserRewardBps of principal
    function _calculateMaxUserReward(uint256 positionId) internal view returns (uint256) {
        uint256 feesPaid = _positionFeesPaid[positionId];
        if (feesPaid == 0) {
            // No fees paid (first staker): cap at maxUserRewardBps of principal
            // e.g., 20000 bps = 200% of principal, so $100 stake can earn up to $200 in rewards
            Position memory pos = _positions[positionId];
            return (pos.amount * params.maxUserRewardBps) / BPS;
        }
        // maxUserRewardBps is the multiplier (e.g., 20000 = 2x fees paid)
        return (feesPaid * params.maxUserRewardBps) / BPS;
    }

    /// @notice Calculate late entry fee based on total principal staked
    /// @dev Formula: feeBps = min(baseFee + totalPrincipal / scale, maxFee)
    function _calculateLateEntryFeeBps(uint256 totalPrincipal) internal view returns (uint256) {
        uint256 baseFee = params.lateEntryFeeBaseBps;
        uint256 maxFee = params.lateEntryFeeMaxBps;
        uint256 scale = params.lateEntryFeeScale;

        // Avoid division by zero
        if (scale == 0) {
            return baseFee;
        }

        uint256 scaledFee = baseFee + (totalPrincipal / scale);
        return _min(scaledFee, maxFee);
    }

    /// @notice Return minimum of two values
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
