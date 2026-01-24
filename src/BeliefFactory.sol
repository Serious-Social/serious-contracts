// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBeliefFactory} from "./interfaces/IBeliefFactory.sol";
import {BeliefMarket} from "./BeliefMarket.sol";
import {MarketParams} from "./types/BeliefTypes.sol";

/// @title BeliefFactory
/// @notice Factory for creating BeliefMarket instances using minimal proxies
/// @dev Uses EIP-1167 clones for gas-efficient deployment
contract BeliefFactory is IBeliefFactory, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The BeliefMarket implementation contract
    address public immutable implementation;

    /// @notice The USDC token address
    address public immutable usdc;

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

    /// @notice Internal function to create and initialize a market
    function _createMarket(bytes32 postId, uint256 initialCommitment, MarketParams memory params)
        internal
        returns (address market)
    {
        if (_markets[postId] != address(0)) revert MarketAlreadyExists();

        // Deploy minimal proxy
        market = Clones.clone(implementation);

        // Store mapping
        _markets[postId] = market;
        _marketCount++;

        // If author is providing initial commitment, transfer USDC to market first
        if (initialCommitment > 0) {
            IERC20(usdc).safeTransferFrom(msg.sender, market, initialCommitment);
        }

        // Initialize the market
        BeliefMarket(market).initialize(postId, usdc, params, msg.sender, initialCommitment);

        emit MarketCreated(postId, market, msg.sender);
    }
}
