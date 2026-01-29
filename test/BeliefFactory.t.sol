// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BeliefFactory} from "../src/BeliefFactory.sol";
import {BeliefMarket} from "../src/BeliefMarket.sol";
import {IBeliefFactory} from "../src/interfaces/IBeliefFactory.sol";
import {Side, Position, MarketParams, MarketState} from "../src/types/BeliefTypes.sol";
import {MockUSDC} from "../src/mock/MockUSDC.sol";

contract BeliefFactoryTest is Test {
    BeliefFactory public factory;
    MockUSDC public usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public owner = makeAddr("owner");

    bytes32 public constant POST_ID_1 = keccak256("post-1");
    bytes32 public constant POST_ID_2 = keccak256("post-2");

    // Default market params
    uint32 constant LOCK_PERIOD = 30 days;
    uint32 constant MIN_REWARD_DURATION = 7 days;
    uint16 constant MAX_SRP_BPS = 1000;
    uint16 constant MAX_USER_REWARD_BPS = 20000;
    uint16 constant LATE_ENTRY_FEE_BASE_BPS = 50;
    uint16 constant LATE_ENTRY_FEE_MAX_BPS = 500;
    uint64 constant LATE_ENTRY_FEE_SCALE = 1000e6;
    uint16 constant AUTHOR_PREMIUM_BPS = 200;
    uint64 constant MIN_STAKE = 5e6;
    uint64 constant MAX_STAKE = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(owner);
        factory = new BeliefFactory(address(usdc), _defaultParams());

        // Mint USDC to test users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        // Approve factory for all users
        vm.prank(alice);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _defaultParams() internal pure returns (MarketParams memory) {
        return MarketParams({
            lockPeriod: LOCK_PERIOD,
            minRewardDuration: MIN_REWARD_DURATION,
            maxSrpBps: MAX_SRP_BPS,
            maxUserRewardBps: MAX_USER_REWARD_BPS,
            lateEntryFeeBaseBps: LATE_ENTRY_FEE_BASE_BPS,
            lateEntryFeeMaxBps: LATE_ENTRY_FEE_MAX_BPS,
            lateEntryFeeScale: LATE_ENTRY_FEE_SCALE,
            authorPremiumBps: AUTHOR_PREMIUM_BPS,
            yieldBearingEscrow: false,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE
        });
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(factory.usdc(), address(usdc));
        assertEq(factory.owner(), owner);
        assertEq(factory.marketCount(), 0);
        assertTrue(factory.implementation() != address(0));

        MarketParams memory params = factory.getDefaultParams();
        assertEq(params.lockPeriod, LOCK_PERIOD);
        assertEq(params.authorPremiumBps, AUTHOR_PREMIUM_BPS);
    }

    function test_Constructor_RevertOnZeroUsdc() public {
        vm.expectRevert(IBeliefFactory.InvalidParams.selector);
        new BeliefFactory(address(0), _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE MARKET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarket_NoInitialCommitment() public {
        vm.prank(alice);
        address market = factory.createMarket(POST_ID_1, 0);

        assertTrue(market != address(0));
        assertEq(factory.getMarket(POST_ID_1), market);
        assertTrue(factory.marketExists(POST_ID_1));
        assertEq(factory.marketCount(), 1);

        // Verify market is initialized correctly
        BeliefMarket beliefMarket = BeliefMarket(market);
        assertEq(beliefMarket.postId(), POST_ID_1);
        assertEq(address(beliefMarket.usdc()), address(usdc));
        assertEq(beliefMarket.factory(), address(factory));
    }

    function test_CreateMarket_WithInitialCommitment() public {
        uint256 commitment = 10_000e6;
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        address market = factory.createMarket(POST_ID_1, commitment);

        // Verify USDC was transferred
        assertEq(usdc.balanceOf(alice), balanceBefore - commitment);
        assertEq(usdc.balanceOf(market), commitment);

        // Verify author has a position
        BeliefMarket beliefMarket = BeliefMarket(market);
        uint256[] memory positions = beliefMarket.getUserPositions(alice);
        assertEq(positions.length, 1);

        // Verify premium was deducted
        uint256 premium = (commitment * AUTHOR_PREMIUM_BPS) / 10000;
        uint256 netAmount = commitment - premium;
        Position memory pos = beliefMarket.getPosition(positions[0]);
        assertEq(pos.amount, netAmount);

        // Verify SRP received premium
        MarketState memory state = beliefMarket.getMarketState();
        assertEq(state.srpBalance, premium);
    }

    function test_CreateMarket_EmitsEvent() public {
        // We check indexed params (postId, author) but not the market address
        vm.expectEmit(true, false, true, false);
        emit IBeliefFactory.MarketCreated(POST_ID_1, address(0), alice);

        vm.prank(alice);
        factory.createMarket(POST_ID_1, 0);
    }

    function test_CreateMarket_RevertIfAlreadyExists() public {
        vm.prank(alice);
        factory.createMarket(POST_ID_1, 0);

        vm.prank(bob);
        vm.expectRevert(IBeliefFactory.MarketAlreadyExists.selector);
        factory.createMarket(POST_ID_1, 0);
    }

    function test_CreateMarket_MultipleMarkets() public {
        vm.prank(alice);
        address market1 = factory.createMarket(POST_ID_1, 0);

        vm.prank(bob);
        address market2 = factory.createMarket(POST_ID_2, 0);

        assertTrue(market1 != market2);
        assertEq(factory.getMarket(POST_ID_1), market1);
        assertEq(factory.getMarket(POST_ID_2), market2);
        assertEq(factory.marketCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                     CREATE MARKET WITH PARAMS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateMarketWithParams() public {
        MarketParams memory customParams = MarketParams({
            lockPeriod: 60 days,
            minRewardDuration: 14 days,
            maxSrpBps: 2000,
            maxUserRewardBps: 30000,
            lateEntryFeeBaseBps: 100,
            lateEntryFeeMaxBps: 1000,
            lateEntryFeeScale: 500e6,
            authorPremiumBps: 300,
            yieldBearingEscrow: false,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE
        });

        vm.prank(alice);
        address market = factory.createMarketWithParams(POST_ID_1, 0, customParams);

        BeliefMarket beliefMarket = BeliefMarket(market);
        MarketParams memory actualParams = beliefMarket.getMarketParams();

        assertEq(actualParams.lockPeriod, 60 days);
        assertEq(actualParams.minRewardDuration, 14 days);
        assertEq(actualParams.authorPremiumBps, 300);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetMarket_ReturnsZeroIfNotExists() public view {
        assertEq(factory.getMarket(POST_ID_1), address(0));
    }

    function test_MarketExists() public {
        assertFalse(factory.marketExists(POST_ID_1));

        vm.prank(alice);
        factory.createMarket(POST_ID_1, 0);

        assertTrue(factory.marketExists(POST_ID_1));
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetDefaultParams() public {
        MarketParams memory newParams = MarketParams({
            lockPeriod: 60 days,
            minRewardDuration: 14 days,
            maxSrpBps: 2000,
            maxUserRewardBps: 30000,
            lateEntryFeeBaseBps: 100,
            lateEntryFeeMaxBps: 1000,
            lateEntryFeeScale: 500e6,
            authorPremiumBps: 300,
            yieldBearingEscrow: false,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE
        });

        vm.prank(owner);
        factory.setDefaultParams(newParams);

        MarketParams memory actualParams = factory.getDefaultParams();
        assertEq(actualParams.lockPeriod, 60 days);
        assertEq(actualParams.authorPremiumBps, 300);
    }

    function test_SetDefaultParams_RevertIfNotOwner() public {
        MarketParams memory newParams = _defaultParams();

        vm.prank(alice);
        vm.expectRevert();
        factory.setDefaultParams(newParams);
    }

    function test_SetDefaultParams_EmitsEvent() public {
        MarketParams memory newParams = _defaultParams();
        newParams.lockPeriod = 60 days;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IBeliefFactory.DefaultParamsUpdated(newParams);
        factory.setDefaultParams(newParams);
    }

    /*//////////////////////////////////////////////////////////////
                          INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CreateMarketAndStake() public {
        // Alice creates a market with initial commitment
        vm.prank(alice);
        address market = factory.createMarket(POST_ID_1, 10_000e6);

        BeliefMarket beliefMarket = BeliefMarket(market);

        // Warp to build weight
        vm.warp(block.timestamp + 1 days);

        // Bob stakes on oppose side
        vm.prank(bob);
        usdc.approve(market, type(uint256).max);
        vm.prank(bob);
        beliefMarket.commitOppose(5_000e6);

        // Check belief curve (should favor support since Alice staked earlier and more)
        vm.warp(block.timestamp + 1 days);
        uint256 beliefValue = beliefMarket.belief();
        assertGt(beliefValue, 0.5e18); // Should be > 50%
    }

    function test_Integration_CloneIsolation() public {
        // Create two markets
        vm.prank(alice);
        address market1 = factory.createMarket(POST_ID_1, 1000e6);

        vm.prank(bob);
        address market2 = factory.createMarket(POST_ID_2, 2000e6);

        BeliefMarket beliefMarket1 = BeliefMarket(market1);
        BeliefMarket beliefMarket2 = BeliefMarket(market2);

        // Verify they are isolated
        assertEq(beliefMarket1.postId(), POST_ID_1);
        assertEq(beliefMarket2.postId(), POST_ID_2);

        MarketState memory state1 = beliefMarket1.getMarketState();
        MarketState memory state2 = beliefMarket2.getMarketState();

        // Different principals (after premium deduction)
        assertTrue(state1.supportPrincipal != state2.supportPrincipal);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CreateMarketWithCommitment(uint256 commitment) public {
        commitment = bound(commitment, MIN_STAKE, MAX_STAKE);
        usdc.mint(alice, commitment);

        vm.startPrank(alice);
        usdc.approve(address(factory), commitment);
        address market = factory.createMarket(POST_ID_1, commitment);
        vm.stopPrank();

        assertTrue(market != address(0));
        assertEq(factory.marketCount(), 1);

        // Verify all funds ended up in the market
        assertEq(usdc.balanceOf(market), commitment);
    }
}
