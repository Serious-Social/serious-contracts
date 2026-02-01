// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBeliefFactory} from "./interfaces/IBeliefFactory.sol";
import {IBeliefVault} from "./interfaces/IBeliefVault.sol";
import {BeliefMarket} from "./BeliefMarket.sol";
import {BeliefVault} from "./BeliefVault.sol";
import {MarketParams} from "./types/BeliefTypes.sol";

/// @title BeliefFactory
/// @notice Factory for creating BeliefMarket instances using minimal proxies
/// @dev Uses EIP-1167 clones for gas-efficient deployment
contract BeliefFactory is IBeliefFactory, Ownable {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The BeliefMarket implementation contract
    address public immutable implementation;

    /// @notice The USDC token address
    address public immutable usdc;

    /// @notice The vault that holds all USDC across markets
    IBeliefVault public immutable vault;

    /// @notice Default parameters for new markets
    MarketParams private _defaultParams;

    /// @notice Mapping from postId to market address
    mapping(bytes32 => address) private _markets;

    /// @notice Total number of markets created
    uint256 private _marketCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy the factory with a BeliefMarket implementation
    /// @param usdc_ The USDC token address
    /// @param defaultParams_ Default parameters for new markets
    constructor(address usdc_, MarketParams memory defaultParams_) Ownable(msg.sender) {
        if (usdc_ == address(0)) revert InvalidParams();

        usdc = usdc_;
        _defaultParams = defaultParams_;

        // Deploy the implementation contract
        implementation = address(new BeliefMarket());

        // Deploy the vault
        vault = IBeliefVault(address(new BeliefVault(address(this), usdc_)));
    }

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBeliefFactory
    function createMarket(bytes32 postId, uint256 initialCommitment) external returns (address market) {
        return _createMarket(postId, initialCommitment, _defaultParams);
    }

    /// @inheritdoc IBeliefFactory
    function createMarketWithParams(bytes32 postId, uint256 initialCommitment, MarketParams calldata params)
        external
        returns (address market)
    {
        return _createMarket(postId, initialCommitment, params);
    }

    /// @notice Update the default market parameters
    /// @param params New default parameters
    /// @dev Only callable by owner
    function setDefaultParams(MarketParams calldata params) external onlyOwner {
        _defaultParams = params;
        emit DefaultParamsUpdated(params);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBeliefFactory
    function getMarket(bytes32 postId) external view returns (address market) {
        return _markets[postId];
    }

    /// @inheritdoc IBeliefFactory
    function marketExists(bytes32 postId) external view returns (bool exists) {
        return _markets[postId] != address(0);
    }

    /// @inheritdoc IBeliefFactory
    function getDefaultParams() external view returns (MarketParams memory params) {
        return _defaultParams;
    }

    /// @inheritdoc IBeliefFactory
    function marketCount() external view returns (uint256 count) {
        return _marketCount;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBeliefFactory
    function getVault() external view returns (address) {
        return address(vault);
    }

    /// @notice Internal function to create and initialize a market
    function _createMarket(bytes32 postId, uint256 initialCommitment, MarketParams memory params)
        internal
        returns (address market)
    {
        if (_markets[postId] != address(0)) revert MarketAlreadyExists();

        // Deploy minimal proxy
        market = Clones.clone(implementation);

        // Register market with vault before initialize (so market can pull USDC)
        vault.registerMarket(market);

        // Store mapping
        _markets[postId] = market;
        _marketCount++;

        // Initialize the market (vault pulls USDC from author during init if needed)
        BeliefMarket(market).initialize(postId, address(vault), params, msg.sender, initialCommitment);

        emit MarketCreated(postId, market, msg.sender);
    }
}
