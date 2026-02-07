// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IBeliefFactory} from "./interfaces/IBeliefFactory.sol";
import {IBeliefVault} from "./interfaces/IBeliefVault.sol";
import {BeliefMarket} from "./BeliefMarket.sol";
import {BeliefVault} from "./BeliefVault.sol";
import {MarketParams} from "./types/BeliefTypes.sol";

/// @title BeliefFactory
/// @notice Factory for creating BeliefMarket instances using minimal proxies
/// @dev Uses EIP-1167 clones for gas-efficient deployment
contract BeliefFactory is IBeliefFactory, Ownable, Pausable {
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
        _validateParams(defaultParams_);

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
    function createMarket(bytes32 postId, uint256 initialCommitment) external whenNotPaused returns (address market) {
        return _createMarket(postId, initialCommitment);
    }

    /// @inheritdoc IBeliefFactory
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IBeliefFactory
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IBeliefFactory
    function pauseVault() external onlyOwner {
        vault.pauseVault();
    }

    /// @inheritdoc IBeliefFactory
    function unpauseVault() external onlyOwner {
        vault.unpauseVault();
    }

    /// @notice Update the default market parameters
    /// @param params New default parameters
    /// @dev Only callable by owner
    function setDefaultParams(MarketParams calldata params) external onlyOwner {
        _validateParams(params);
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

    /// @notice Validate market parameters
    /// @dev Reverts with InvalidParams if any constraint is violated
    function _validateParams(MarketParams memory p) internal pure {
        // BPS fields must not exceed 100%
        if (p.lateEntryFeeBaseBps > 10_000) revert InvalidParams();
        if (p.lateEntryFeeMaxBps > 10_000) revert InvalidParams();
        if (p.authorPremiumBps > 10_000) revert InvalidParams();
        if (p.earlyWithdrawPenaltyBps > 10_000) revert InvalidParams();

        // Late entry fee ordering
        if (p.lateEntryFeeBaseBps > p.lateEntryFeeMaxBps) revert InvalidParams();

        // Scale must be non-zero to avoid division by zero
        if (p.lateEntryFeeScale == 0) revert InvalidParams();

        // Stake bounds
        if (p.minStake == 0) revert InvalidParams();
        if (p.minStake > p.maxStake) revert InvalidParams();

        // Lock period bounds
        if (p.lockPeriod < 1 days) revert InvalidParams();
        if (p.lockPeriod > 365 days) revert InvalidParams();

        // Min reward duration must not exceed lock period
        if (p.minRewardDuration > p.lockPeriod) revert InvalidParams();
    }

    /// @notice Internal function to create and initialize a market
    function _createMarket(bytes32 postId, uint256 initialCommitment) internal returns (address market) {
        if (_markets[postId] != address(0)) revert MarketAlreadyExists();

        // Deploy minimal proxy
        market = Clones.clone(implementation);

        // Register market with vault before initialize (so market can pull USDC)
        vault.registerMarket(market);

        // Store mapping
        _markets[postId] = market;
        _marketCount++;

        // Initialize the market (vault pulls USDC from author during init if needed)
        BeliefMarket(market).initialize(postId, address(vault), _defaultParams, msg.sender, initialCommitment);

        emit MarketCreated(postId, market, msg.sender);
    }
}
