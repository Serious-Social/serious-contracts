// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBeliefVault
/// @notice Interface for centralized USDC custody across all belief markets
interface IBeliefVault {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a market is registered with the vault
    event MarketRegistered(address indexed market);

    /// @notice Emitted when USDC is locked for a market
    event Locked(address indexed market, address indexed user, uint256 amount);

    /// @notice Emitted when USDC is released from a market
    event Released(address indexed market, address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not the factory
    error NotFactory();

    /// @notice Thrown when caller is not a registered market
    error NotRegisteredMarket();

    /// @notice Thrown when a market tries to release more than its balance
    error InsufficientMarketBalance();

    /// @notice Thrown when trying to register a market that is already registered
    error MarketAlreadyRegistered();

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a market address (only callable by factory)
    /// @param market The market address to register
    function registerMarket(address market) external;

    /// @notice Pull USDC from a user into the vault for a market (only callable by registered markets)
    /// @param user The user to pull USDC from
    /// @param amount The amount to lock
    function lockForMarket(address user, uint256 amount) external;

    /// @notice Release USDC from the vault to a user for a market (only callable by registered markets)
    /// @param user The user to send USDC to
    /// @param amount The amount to release
    function releaseFromMarket(address user, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the balance allocated to a specific market
    /// @param market The market address
    /// @return balance The market's balance in the vault
    function marketBalance(address market) external view returns (uint256 balance);

    /// @notice Check if a market is registered
    /// @param market The market address
    /// @return registered True if the market is registered
    function isMarketRegistered(address market) external view returns (bool registered);

    /// @notice Get the factory address
    /// @return factory The factory that deployed this vault
    function factory() external view returns (address);

    /// @notice Get the USDC token address
    /// @return usdc The USDC token address
    function usdc() external view returns (address);
}
