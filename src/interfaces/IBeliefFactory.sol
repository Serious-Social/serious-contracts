// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Side, MarketParams} from "../types/BeliefTypes.sol";

/// @title IBeliefFactory
/// @notice Factory interface for creating and managing BeliefMarket instances
/// @dev One BeliefMarket is created per post/claim
interface IBeliefFactory {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new belief market is created
    /// @param postId Unique identifier for the post/claim
    /// @param market Address of the deployed BeliefMarket
    /// @param creator Address of the market creator
    event MarketCreated(bytes32 indexed postId, address indexed market, address indexed creator);

    /// @notice Emitted when default market parameters are updated
    /// @param params New default parameters
    event DefaultParamsUpdated(MarketParams params);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when trying to create a market for an existing post
    error MarketAlreadyExists();

    /// @notice Thrown when querying a non-existent market
    error MarketNotFound();

    /// @notice Thrown when invalid parameters are provided
    error InvalidParams();

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new belief market for a post
    /// @param postId Unique identifier for the post/claim
    /// @param initialCommitment Creator's initial commitment amount (subject to creator premium)
    /// @param initialSide The side the creator commits to (Support or Oppose)
    /// @return market Address of the deployed BeliefMarket
    /// @dev Creator premium is deducted and sent to SRP
    function createMarket(bytes32 postId, uint256 initialCommitment, Side initialSide) external returns (address market);

    /// @notice Pause the factory (no new markets can be created)
    /// @dev Only callable by owner
    function pause() external;

    /// @notice Unpause the factory
    /// @dev Only callable by owner
    function unpause() external;

    /// @notice Pause the vault (no new deposits, withdrawals still work)
    /// @dev Only callable by owner
    function pauseVault() external;

    /// @notice Unpause the vault
    /// @dev Only callable by owner
    function unpauseVault() external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the market address for a post
    /// @param postId The post identifier
    /// @return market Address of the BeliefMarket (zero if not exists)
    function getMarket(bytes32 postId) external view returns (address market);

    /// @notice Check if a market exists for a post
    /// @param postId The post identifier
    /// @return exists True if market exists
    function marketExists(bytes32 postId) external view returns (bool exists);

    /// @notice Get the default market parameters
    /// @return params Default MarketParams used for new markets
    function getDefaultParams() external view returns (MarketParams memory params);

    /// @notice Get the USDC token address
    /// @return usdc Address of the USDC token
    function usdc() external view returns (address);

    /// @notice Get the vault address
    /// @return vault Address of the BeliefVault
    function getVault() external view returns (address);

    /// @notice Get total number of markets created
    /// @return count Number of markets
    function marketCount() external view returns (uint256 count);
}
