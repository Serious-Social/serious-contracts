// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Side, Position, MarketParams, MarketState} from "../types/BeliefTypes.sol";

/// @title IBeliefMarket
/// @notice Interface for a belief market where users stake USDC to signal support or opposition
/// @dev Implements time-weighted signal mechanics where patience is rewarded over speed
interface IBeliefMarket {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user commits to a side
    /// @param positionId Unique identifier for the position
    /// @param user Address of the staker
    /// @param side Support or Oppose
    /// @param amount Principal amount staked
    /// @param unlockTimestamp When the position becomes withdrawable
    event Committed(
        uint256 indexed positionId,
        address indexed user,
        Side side,
        uint256 amount,
        uint48 unlockTimestamp
    );

    /// @notice Emitted when a user withdraws their principal
    /// @param positionId The position being withdrawn
    /// @param user Address of the withdrawer
    /// @param amount Principal amount withdrawn
    event Withdrawn(uint256 indexed positionId, address indexed user, uint256 amount);

    /// @notice Emitted when a user claims rewards
    /// @param positionId The position claiming rewards
    /// @param user Address of the claimer
    /// @param amount Reward amount claimed
    event RewardsClaimed(uint256 indexed positionId, address indexed user, uint256 amount);

    /// @notice Emitted when fees are added to the Signal Reward Pool
    /// @param amount Amount added to SRP
    /// @param source Description of fee source (e.g., "late_entry", "author_premium")
    event SrpFunded(uint256 amount, string source);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when stake amount is zero
    error ZeroAmount();

    /// @notice Thrown when trying to withdraw before unlock time
    error PositionLocked();

    /// @notice Thrown when position has already been withdrawn
    error AlreadyWithdrawn();

    /// @notice Thrown when caller is not the position owner
    error NotPositionOwner();

    /// @notice Thrown when position does not exist
    error PositionNotFound();

    /// @notice Thrown when trying to claim with no accrued rewards
    error NoRewardsToClaim();

    /// @notice Thrown when reward duration minimum not met
    error MinRewardDurationNotMet();

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake USDC to signal support for the claim
    /// @param amount Amount of USDC to stake
    /// @return positionId Unique identifier for the created position
    function commitSupport(uint256 amount) external returns (uint256 positionId);

    /// @notice Stake USDC to signal opposition to the claim
    /// @param amount Amount of USDC to stake
    /// @return positionId Unique identifier for the created position
    function commitOppose(uint256 amount) external returns (uint256 positionId);

    /// @notice Withdraw principal after lock period expires
    /// @param positionId The position to withdraw
    function withdraw(uint256 positionId) external;

    /// @notice Claim accrued rewards from the Signal Reward Pool
    /// @param positionId The position to claim rewards for
    /// @return amount The amount of rewards claimed
    function claimRewards(uint256 positionId) external returns (uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the current belief curve value
    /// @return belief Value from 0 to 1e18 representing support ratio
    /// @dev Returns 0.5e18 if both sides have zero weight
    function belief() external view returns (uint256);

    /// @notice Get the time-weighted signal for a side at current time
    /// @param side Support or Oppose
    /// @return weight The time-weighted signal W(t) = t * P - S
    function getWeight(Side side) external view returns (uint256 weight);

    /// @notice Get a position's details
    /// @param positionId The position to query
    /// @return position The position struct
    function getPosition(uint256 positionId) external view returns (Position memory position);

    /// @notice Get pending rewards for a position
    /// @param positionId The position to query
    /// @return amount Pending reward amount
    function pendingRewards(uint256 positionId) external view returns (uint256 amount);

    /// @notice Get the full market state
    /// @return state Current market state snapshot
    function getMarketState() external view returns (MarketState memory state);

    /// @notice Get the market configuration
    /// @return params Market parameters
    function getMarketParams() external view returns (MarketParams memory params);

    /// @notice Get the post ID this market is associated with
    /// @return postId The post identifier
    function postId() external view returns (bytes32);

    /// @notice Get all position IDs for a user
    /// @param user The user address
    /// @return positionIds Array of position IDs owned by the user
    function getUserPositions(address user) external view returns (uint256[] memory positionIds);
}
