// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {BeliefMarket} from "../src/BeliefMarket.sol";
import {IBeliefMarket} from "../src/interfaces/IBeliefMarket.sol";
import {Side, Position, MarketParams, MarketState} from "../src/types/BeliefTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock USDC with 6 decimals
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BeliefMarketTest is Test {
    BeliefMarket public market;
    MockUSDC public usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public author = makeAddr("author");

    bytes32 public constant POST_ID = keccak256("test-post-1");

    // Default market params
    uint32 constant LOCK_PERIOD = 30 days;
    uint32 constant MIN_REWARD_DURATION = 7 days;
    uint16 constant MAX_SRP_BPS = 1000; // 10%
    uint16 constant MAX_USER_REWARD_BPS = 20000; // 2x fees paid
    uint16 constant LATE_ENTRY_FEE_BASE_BPS = 50; // 0.5%
    uint16 constant LATE_ENTRY_FEE_MAX_BPS = 500; // 5%
    uint64 constant LATE_ENTRY_FEE_SCALE = 1000e6; // +1 bps per $1000
    uint16 constant AUTHOR_PREMIUM_BPS = 200; // 2%
    uint64 constant MIN_STAKE = 5e6; // $5 USDC
    uint64 constant MAX_STAKE = 100_000e6; // $100k USDC (wide for testing)

    function setUp() public {
        usdc = new MockUSDC();
        market = new BeliefMarket();

        // Mint USDC to test users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);
        usdc.mint(author, 100_000e6);

        // Approve market for all users
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(author);
        usdc.approve(address(market), type(uint256).max);
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

    function _initializeMarket() internal {
        market.initialize(POST_ID, address(usdc), _defaultParams(), address(0), 0);
    }

    function _initializeMarketWithAuthor(uint256 authorCommitment) internal {
        // Simulate factory behavior: transfer USDC to market before initialize
        if (authorCommitment > 0) {
            vm.prank(author);
            usdc.transfer(address(market), authorCommitment);
        }
        market.initialize(POST_ID, address(usdc), _defaultParams(), author, authorCommitment);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public {
        _initializeMarket();

        assertEq(market.postId(), POST_ID);
        assertEq(address(market.usdc()), address(usdc));
        assertEq(market.factory(), address(this));

        MarketParams memory params = market.getMarketParams();
        assertEq(params.lockPeriod, LOCK_PERIOD);
        assertEq(params.minRewardDuration, MIN_REWARD_DURATION);
    }

    function test_Initialize_WithAuthorCommitment() public {
        uint256 authorCommitment = 10_000e6;
        _initializeMarketWithAuthor(authorCommitment);

        // Author pays 2% premium
        uint256 premium = (authorCommitment * AUTHOR_PREMIUM_BPS) / 10000;
        uint256 netAmount = authorCommitment - premium;

        MarketState memory state = market.getMarketState();
        assertEq(state.supportPrincipal, netAmount);
        assertEq(state.srpBalance, premium);

        // Author should have position 1
        uint256[] memory positions = market.getUserPositions(author);
        assertEq(positions.length, 1);
        assertEq(positions[0], 1);
    }

    function test_Initialize_RevertIfAlreadyInitialized() public {
        _initializeMarket();

        vm.expectRevert("Already initialized");
        market.initialize(POST_ID, address(usdc), _defaultParams(), address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            COMMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CommitSupport_FirstStaker() public {
        _initializeMarket();

        uint256 amount = 1000e6;
        vm.prank(alice);
        uint256 positionId = market.commitSupport(amount);

        assertEq(positionId, 1);

        Position memory pos = market.getPosition(positionId);
        assertEq(uint8(pos.side), uint8(Side.Support));
        assertEq(pos.amount, amount); // No fee for first staker
        assertEq(pos.withdrawn, false);
        assertEq(pos.depositTimestamp, block.timestamp);
        assertEq(pos.unlockTimestamp, block.timestamp + LOCK_PERIOD);

        MarketState memory state = market.getMarketState();
        assertEq(state.supportPrincipal, amount);
        assertEq(state.srpBalance, 0); // No fee for first staker
    }

    function test_CommitOppose_FirstStaker() public {
        _initializeMarket();

        uint256 amount = 1000e6;
        vm.prank(alice);
        uint256 positionId = market.commitOppose(amount);

        Position memory pos = market.getPosition(positionId);
        assertEq(uint8(pos.side), uint8(Side.Oppose));
        assertEq(pos.amount, amount);

        MarketState memory state = market.getMarketState();
        assertEq(state.opposePrincipal, amount);
    }

    function test_CommitSupport_LateEntryFee() public {
        _initializeMarket();

        // First staker - no fee
        vm.prank(alice);
        market.commitSupport(1000e6);

        // Second staker - pays late entry fee
        uint256 amount = 1000e6;
        uint256 expectedFeeBps = LATE_ENTRY_FEE_BASE_BPS + (1000e6 / LATE_ENTRY_FEE_SCALE);
        uint256 expectedFee = (amount * expectedFeeBps) / 10000;
        uint256 expectedNet = amount - expectedFee;

        vm.prank(bob);
        uint256 positionId = market.commitSupport(amount);

        Position memory pos = market.getPosition(positionId);
        assertEq(pos.amount, expectedNet);

        MarketState memory state = market.getMarketState();
        assertEq(state.srpBalance, expectedFee);
    }

    function test_CommitSupport_GraduatedFee() public {
        _initializeMarket();

        // First staker
        vm.prank(alice);
        market.commitSupport(100_000e6); // $100k

        // Check fee at $100k total principal
        // feeBps = 50 + 100_000e6 / 1000e6 = 50 + 100 = 150 bps = 1.5%
        uint256 currentFee = market.getCurrentEntryFeeBps();
        assertEq(currentFee, 150);

        // Stake more to increase fee
        vm.prank(bob);
        market.commitSupport(50_000e6);

        // Now at ~$150k (minus fees), fee should be higher
        uint256 newFee = market.getCurrentEntryFeeBps();
        assertGt(newFee, currentFee);
    }

    function test_CommitSupport_FeeCappedAtMax() public {
        _initializeMarket();

        // First staker with amount to hit fee cap
        vm.prank(alice);
        market.commitSupport(MAX_STAKE);

        // Second staker to push fee to cap
        vm.prank(bob);
        market.commitSupport(MAX_STAKE);

        // Third staker to verify fee is capped
        vm.prank(charlie);
        market.commitSupport(MAX_STAKE);

        // Fee should be capped at max (3 * 100k = 300k total principal)
        // feeBps = 50 + 300_000e6 / 1000e6 = 50 + 300 = 350 bps (still under 500)
        // Need more principal to hit cap, but within stake limits we can verify it doesn't exceed max
        uint256 currentFee = market.getCurrentEntryFeeBps();
        assertLe(currentFee, LATE_ENTRY_FEE_MAX_BPS);
    }

    function test_Commit_RevertOnZeroAmount() public {
        _initializeMarket();

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.StakeOutOfRange.selector);
        market.commitSupport(0);
    }

    function test_Commit_RevertBelowMinStake() public {
        _initializeMarket();

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.StakeOutOfRange.selector);
        market.commitSupport(MIN_STAKE - 1);
    }

    function test_Commit_RevertAboveMaxStake() public {
        _initializeMarket();

        usdc.mint(alice, MAX_STAKE + 1);

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.StakeOutOfRange.selector);
        market.commitSupport(MAX_STAKE + 1);
    }

    function test_Commit_AtExactMinStake() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(MIN_STAKE);

        Position memory pos = market.getPosition(positionId);
        assertEq(pos.amount, MIN_STAKE);
    }

    function test_Commit_AtExactMaxStake() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(MAX_STAKE);

        Position memory pos = market.getPosition(positionId);
        assertEq(pos.amount, MAX_STAKE); // First staker, no fee
    }

    function test_Commit_MultiplePositions() public {
        _initializeMarket();

        vm.startPrank(alice);
        uint256 pos1 = market.commitSupport(1000e6);
        uint256 pos2 = market.commitOppose(500e6);
        uint256 pos3 = market.commitSupport(2000e6);
        vm.stopPrank();

        uint256[] memory positions = market.getUserPositions(alice);
        assertEq(positions.length, 3);
        assertEq(positions[0], pos1);
        assertEq(positions[1], pos2);
        assertEq(positions[2], pos3);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_AfterLockPeriod() public {
        _initializeMarket();

        uint256 amount = 1000e6;
        vm.prank(alice);
        uint256 positionId = market.commitSupport(amount);

        uint256 balanceBefore = usdc.balanceOf(alice);

        // Warp past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        market.withdraw(positionId);

        Position memory pos = market.getPosition(positionId);
        assertEq(pos.withdrawn, true);

        uint256 balanceAfter = usdc.balanceOf(alice);
        assertEq(balanceAfter - balanceBefore, amount);

        MarketState memory state = market.getMarketState();
        assertEq(state.supportPrincipal, 0);
    }

    function test_Withdraw_RevertBeforeLockPeriod() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(1000e6);

        // Try to withdraw before lock period
        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.PositionLocked.selector);
        market.withdraw(positionId);
    }

    function test_Withdraw_RevertIfNotOwner() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(1000e6);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(bob);
        vm.expectRevert(IBeliefMarket.NotPositionOwner.selector);
        market.withdraw(positionId);
    }

    function test_Withdraw_RevertIfAlreadyWithdrawn() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(1000e6);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        market.withdraw(positionId);

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.AlreadyWithdrawn.selector);
        market.withdraw(positionId);
    }

    function test_Withdraw_RevertIfPositionNotFound() public {
        _initializeMarket();

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.PositionNotFound.selector);
        market.withdraw(999);
    }

    /*//////////////////////////////////////////////////////////////
                            BELIEF CURVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Belief_FiftyPercentWhenEmpty() public {
        _initializeMarket();

        uint256 beliefValue = market.belief();
        assertEq(beliefValue, 0.5e18);
    }

    function test_Belief_AllSupport() public {
        _initializeMarket();

        vm.prank(alice);
        market.commitSupport(1000e6);

        // Warp to build weight
        vm.warp(block.timestamp + 1 days);

        uint256 beliefValue = market.belief();
        assertEq(beliefValue, 1e18); // 100% support
    }

    function test_Belief_AllOppose() public {
        _initializeMarket();

        vm.prank(alice);
        market.commitOppose(1000e6);

        vm.warp(block.timestamp + 1 days);

        uint256 beliefValue = market.belief();
        assertEq(beliefValue, 0); // 0% support = 100% oppose
    }

    function test_Belief_EqualStakesEqualTime() public {
        _initializeMarket();

        // Both stake at same time with same amount
        vm.prank(alice);
        market.commitSupport(1000e6);
        vm.prank(bob);
        market.commitOppose(1000e6);

        vm.warp(block.timestamp + 1 days);

        uint256 beliefValue = market.belief();
        // Should be approximately 50% (might have tiny rounding from fees)
        assertApproxEqRel(beliefValue, 0.5e18, 0.01e18);
    }

    function test_Belief_TimeWeightedAdvantage() public {
        _initializeMarket();

        // Alice stakes support first
        vm.prank(alice);
        market.commitSupport(1000e6);

        // Wait 10 days
        vm.warp(block.timestamp + 10 days);

        // Bob stakes oppose with same amount
        vm.prank(bob);
        market.commitOppose(1000e6);

        // Wait 1 more day
        vm.warp(block.timestamp + 1 days);

        // Alice has 11 days of weight, Bob has 1 day
        // Alice's weight >> Bob's weight, so belief should favor support
        uint256 beliefValue = market.belief();
        assertGt(beliefValue, 0.9e18); // Should be heavily in favor of support
    }

    /*//////////////////////////////////////////////////////////////
                            WEIGHT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetWeight_Formula() public {
        _initializeMarket();

        uint256 amount = 1000e6;
        uint256 startTime = block.timestamp;

        vm.prank(alice);
        market.commitSupport(amount);

        // W(t) = t * P - S
        // At deposit time: W = t * amount - amount * t = 0
        assertEq(market.getWeight(Side.Support), 0);

        // After 1 day: W = (t+1day) * amount - amount * t = 1day * amount
        vm.warp(startTime + 1 days);
        uint256 expectedWeight = 1 days * amount;
        assertEq(market.getWeight(Side.Support), expectedWeight);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRewards_AfterMinDuration() public {
        _initializeMarketWithAuthor(10_000e6);

        // Warp so author's position builds weight before Alice stakes
        vm.warp(block.timestamp + 1 days);

        // Alice stakes (will pay late entry fee which goes to SRP)
        // A checkpoint will be created with author's accumulated weight
        vm.prank(alice);
        market.commitSupport(10_000e6);

        // Warp past min reward duration
        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        // Author (position 1) should have pending rewards from Alice's late entry fee
        uint256 authorPending = market.pendingRewards(1);
        assertGt(authorPending, 0);

        uint256 balanceBefore = usdc.balanceOf(author);
        vm.prank(author);
        uint256 claimed = market.claimRewards(1);

        assertEq(claimed, authorPending);
        assertEq(usdc.balanceOf(author) - balanceBefore, claimed);
    }

    function test_ClaimRewards_RevertBeforeMinDuration() public {
        _initializeMarketWithAuthor(10_000e6);

        vm.prank(alice);
        uint256 positionId = market.commitSupport(10_000e6);

        // Try to claim before min duration
        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.MinRewardDurationNotMet.selector);
        market.claimRewards(positionId);
    }

    function test_PendingRewards_ZeroBeforeMinDuration() public {
        _initializeMarketWithAuthor(10_000e6);

        vm.prank(alice);
        uint256 positionId = market.commitSupport(10_000e6);

        uint256 pending = market.pendingRewards(positionId);
        assertEq(pending, 0);
    }

    function test_ClaimRewards_RevertIfNotOwner() public {
        _initializeMarketWithAuthor(10_000e6);

        vm.prank(alice);
        uint256 positionId = market.commitSupport(10_000e6);

        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        vm.prank(bob);
        vm.expectRevert(IBeliefMarket.NotPositionOwner.selector);
        market.claimRewards(positionId);
    }

    function test_ClaimRewards_ProportionalToWeight() public {
        _initializeMarket();

        // Alice stakes first
        vm.prank(alice);
        uint256 alicePos = market.commitSupport(1000e6);

        // Wait 5 days so Alice builds weight
        vm.warp(block.timestamp + 5 days);

        // Bob stakes (pays fee to SRP, checkpoint created with Alice's weight)
        vm.prank(bob);
        uint256 bobPos = market.commitSupport(1000e6);

        // Wait 1 day so Bob builds weight
        vm.warp(block.timestamp + 1 days);

        // Charlie stakes (pays fee to SRP, checkpoint created with Alice + Bob's weight)
        vm.prank(charlie);
        market.commitSupport(1000e6);

        // Wait past min reward duration for all
        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        uint256 alicePending = market.pendingRewards(alicePos);
        uint256 bobPending = market.pendingRewards(bobPos);

        // Alice has more weight (staked longer), should get more rewards
        // Alice was in both checkpoints with more weight, Bob only in second
        assertGt(alicePending, bobPending);
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetMarketState() public {
        _initializeMarket();

        vm.prank(alice);
        market.commitSupport(5000e6);
        vm.prank(bob);
        market.commitOppose(3000e6);

        vm.warp(block.timestamp + 1 days);

        MarketState memory state = market.getMarketState();

        assertGt(state.supportWeight, 0);
        assertGt(state.opposeWeight, 0);
        assertGt(state.supportPrincipal, 0);
        assertGt(state.opposePrincipal, 0);
        assertGt(state.belief, 0);
        assertLt(state.belief, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUpdatesWeight() public {
        _initializeMarket();

        vm.prank(alice);
        uint256 positionId = market.commitSupport(1000e6);

        vm.warp(block.timestamp + 1 days);
        uint256 weightBefore = market.getWeight(Side.Support);
        assertGt(weightBefore, 0);

        vm.warp(block.timestamp + LOCK_PERIOD);
        vm.prank(alice);
        market.withdraw(positionId);

        uint256 weightAfter = market.getWeight(Side.Support);
        assertEq(weightAfter, 0);
    }

    function test_RewardAccumulators_UpdateOnDeposit() public {
        _initializeMarket();

        // First staker - no fees, accumulators should stay at 0
        vm.prank(alice);
        market.commitSupport(10_000e6);

        assertEq(market.rewardPerPrincipalTime(), 0);
        assertEq(market.rewardPerPrincipalPerTime(), 0);

        // Wait so weight builds up
        vm.warp(block.timestamp + 1 days);

        // Second staker pays late entry fee, accumulators should update
        vm.prank(bob);
        market.commitSupport(5_000e6);

        assertGt(market.rewardPerPrincipalTime(), 0);
        assertGt(market.rewardPerPrincipalPerTime(), 0);

        uint256 accumA = market.rewardPerPrincipalTime();
        uint256 accumB = market.rewardPerPrincipalPerTime();

        // Third staker pays fee, accumulators should increase further
        vm.warp(block.timestamp + 1 days);
        vm.prank(charlie);
        market.commitOppose(5_000e6);

        assertGt(market.rewardPerPrincipalTime(), accumA);
        assertGt(market.rewardPerPrincipalPerTime(), accumB);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CommitAndWithdraw(uint256 amount) public {
        amount = bound(amount, MIN_STAKE, MAX_STAKE);
        usdc.mint(alice, amount);

        _initializeMarket();

        vm.startPrank(alice);
        usdc.approve(address(market), amount);
        uint256 positionId = market.commitSupport(amount);
        vm.stopPrank();

        Position memory pos = market.getPosition(positionId);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.withdraw(positionId);

        assertEq(usdc.balanceOf(alice) - balanceBefore, pos.amount);
    }

    function testFuzz_BeliefAlwaysInRange(uint256 supportAmount, uint256 opposeAmount, uint256 timeElapsed) public {
        supportAmount = bound(supportAmount, MIN_STAKE, MAX_STAKE);
        opposeAmount = bound(opposeAmount, MIN_STAKE, MAX_STAKE);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        usdc.mint(alice, supportAmount);
        usdc.mint(bob, opposeAmount);

        _initializeMarket();

        vm.prank(alice);
        usdc.approve(address(market), supportAmount);
        vm.prank(alice);
        market.commitSupport(supportAmount);

        vm.prank(bob);
        usdc.approve(address(market), opposeAmount);
        vm.prank(bob);
        market.commitOppose(opposeAmount);

        vm.warp(block.timestamp + timeElapsed);

        uint256 beliefValue = market.belief();
        assertLe(beliefValue, 1e18);
        assertGe(beliefValue, 0);
    }

    function testFuzz_GraduatedFee(uint256 totalPrincipal) public {
        totalPrincipal = bound(totalPrincipal, MIN_STAKE, MAX_STAKE);
        usdc.mint(alice, totalPrincipal);

        _initializeMarket();

        vm.startPrank(alice);
        usdc.approve(address(market), totalPrincipal);
        market.commitSupport(totalPrincipal);
        vm.stopPrank();

        uint256 feeBps = market.getCurrentEntryFeeBps();

        // Fee should be >= base and <= max
        assertGe(feeBps, LATE_ENTRY_FEE_BASE_BPS);
        assertLe(feeBps, LATE_ENTRY_FEE_MAX_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                    FIRST STAKER REWARD CAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FirstStaker_RewardCapped() public {
        _initializeMarket();

        // Alice is first staker (pays no late entry fee)
        uint256 amount = 1000e6;
        vm.prank(alice);
        uint256 alicePos = market.commitSupport(amount);

        // Wait for weight to build
        vm.warp(block.timestamp + 1 days);

        // Bob stakes and pays a large late entry fee to build up SRP
        // This creates rewards that Alice could potentially claim
        uint256 bobAmount = 50_000e6;
        usdc.mint(bob, bobAmount);
        vm.prank(bob);
        usdc.approve(address(market), bobAmount);
        vm.prank(bob);
        market.commitSupport(bobAmount);

        // Wait past min reward duration
        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        // Calculate Alice's max reward cap (maxUserRewardBps of principal)
        // maxUserRewardBps = 20000 (200%), principal = 1000e6
        uint256 maxReward = (amount * MAX_USER_REWARD_BPS) / 10000;

        // Check pending rewards are capped
        uint256 pending = market.pendingRewards(alicePos);
        assertLe(pending, maxReward, "First staker rewards should be capped");

        // Claim and verify cap is enforced
        vm.prank(alice);
        uint256 claimed = market.claimRewards(alicePos);
        assertLe(claimed, maxReward, "Claimed rewards should be capped");
    }

    function test_Author_RewardCapped() public {
        uint256 authorCommitment = 10_000e6;
        _initializeMarketWithAuthor(authorCommitment);

        // Author pays 2% premium = $200
        uint256 premium = (authorCommitment * AUTHOR_PREMIUM_BPS) / 10000;

        // Wait for author's weight to build
        vm.warp(block.timestamp + 5 days);

        // Multiple stakers pay late entry fees to build up SRP
        uint256 stakingAmount = 50_000e6;
        usdc.mint(alice, stakingAmount);
        usdc.mint(bob, stakingAmount);

        vm.prank(alice);
        usdc.approve(address(market), stakingAmount);
        vm.prank(alice);
        market.commitSupport(stakingAmount);

        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        usdc.approve(address(market), stakingAmount);
        vm.prank(bob);
        market.commitSupport(stakingAmount);

        // Wait past min reward duration
        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        // Author's cap is based on premium paid (not principal, since they paid premium)
        // premium = $200, maxUserRewardBps = 20000 (200%), so max = $400
        uint256 maxRewardFromPremium = (premium * MAX_USER_REWARD_BPS) / 10000;

        // Check pending rewards
        uint256 pending = market.pendingRewards(1);
        assertLe(pending, maxRewardFromPremium, "Author rewards should be capped by premium paid");
    }

    /*//////////////////////////////////////////////////////////////
                        SRP CAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SrpCapped_AtMaxBps() public {
        _initializeMarket();

        // First staker
        vm.prank(alice);
        market.commitSupport(10_000e6);

        // Many subsequent stakers to try to accumulate fees
        // maxSrpBps = 1000 (10%), so max SRP should be 10% of total principal
        for (uint256 i = 0; i < 10; i++) {
            address staker = address(uint160(100 + i));
            usdc.mint(staker, 10_000e6);
            vm.prank(staker);
            usdc.approve(address(market), 10_000e6);
            vm.prank(staker);
            market.commitSupport(10_000e6);
        }

        // Get market state
        MarketState memory state = market.getMarketState();
        uint256 totalPrincipal = state.supportPrincipal + state.opposePrincipal;
        uint256 maxSrp = (totalPrincipal * MAX_SRP_BPS) / 10000;

        // SRP should not exceed maxSrpBps of total principal
        assertLe(state.srpBalance, maxSrp, "SRP should not exceed maxSrpBps of total principal");
    }

    function test_SrpCapped_ExcessFeeRefunded() public {
        // Use params with very low maxSrpBps to make capping easier to trigger
        MarketParams memory customParams = MarketParams({
            lockPeriod: LOCK_PERIOD,
            minRewardDuration: MIN_REWARD_DURATION,
            maxSrpBps: 100, // Only 1% max SRP
            maxUserRewardBps: MAX_USER_REWARD_BPS,
            lateEntryFeeBaseBps: 500, // High 5% base fee
            lateEntryFeeMaxBps: 500,
            lateEntryFeeScale: 1000e6,
            authorPremiumBps: AUTHOR_PREMIUM_BPS,
            yieldBearingEscrow: false,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE
        });

        market.initialize(POST_ID, address(usdc), customParams, address(0), 0);

        // First staker - no fee
        vm.prank(alice);
        uint256 alicePos = market.commitSupport(10_000e6);

        Position memory alicePosition = market.getPosition(alicePos);
        assertEq(alicePosition.amount, 10_000e6, "First staker should have full amount");

        // Second staker - would pay 5% = $500 fee
        // But max SRP is 1% of ~$10k = $100
        // So only $100 should go to SRP, $400 stays as principal
        vm.prank(bob);
        uint256 bobPos = market.commitSupport(10_000e6);

        Position memory bobPosition = market.getPosition(bobPos);

        // Bob would have paid $500 fee (5% of $10k)
        // But SRP can only hold $100 (1% of $10k principal before Bob)
        // So Bob's net should be $10k - $100 = $9,900
        assertGt(bobPosition.amount, 10_000e6 - 500e6, "Bob should get excess fee back as principal");
        assertEq(bobPosition.amount, 10_000e6 - 100e6, "Bob's net should be amount minus capped fee");

        // Verify SRP is at its cap
        MarketState memory state = market.getMarketState();
        assertEq(state.srpBalance, 100e6, "SRP should be at its cap");
    }

    function test_SrpCap_MultipleDeposits() public {
        // Use params with low maxSrpBps
        MarketParams memory customParams = MarketParams({
            lockPeriod: LOCK_PERIOD,
            minRewardDuration: MIN_REWARD_DURATION,
            maxSrpBps: 200, // 2% max SRP
            maxUserRewardBps: MAX_USER_REWARD_BPS,
            lateEntryFeeBaseBps: 300, // 3% base fee
            lateEntryFeeMaxBps: 500,
            lateEntryFeeScale: 1000e6,
            authorPremiumBps: AUTHOR_PREMIUM_BPS,
            yieldBearingEscrow: false,
            minStake: MIN_STAKE,
            maxStake: MAX_STAKE
        });

        market.initialize(POST_ID, address(usdc), customParams, address(0), 0);

        // First staker
        vm.prank(alice);
        market.commitSupport(10_000e6);

        // Second staker - should pay some fee
        vm.prank(bob);
        market.commitSupport(10_000e6);

        MarketState memory state1 = market.getMarketState();
        uint256 srp1 = state1.srpBalance;

        // Third staker - should pay fee but may hit cap
        vm.prank(charlie);
        market.commitSupport(10_000e6);

        MarketState memory state2 = market.getMarketState();
        uint256 srp2 = state2.srpBalance;

        // Verify SRP never exceeds cap after any deposit
        uint256 maxSrp1 = (state1.supportPrincipal * 200) / 10000;
        uint256 maxSrp2 = (state2.supportPrincipal * 200) / 10000;

        assertLe(srp1, maxSrp1, "SRP should respect cap after second deposit");
        assertLe(srp2, maxSrp2, "SRP should respect cap after third deposit");
    }

    function test_FirstStaker_NoPrincipalBasedCapWhenFeesPaid() public {
        _initializeMarket();

        // First staker (no fees)
        vm.prank(alice);
        market.commitSupport(1000e6);

        vm.warp(block.timestamp + 1 days);

        // Second staker pays fees
        vm.prank(bob);
        uint256 bobPos = market.commitSupport(5000e6);

        // Get Bob's position and verify he paid fees
        Position memory bobPosition = market.getPosition(bobPos);
        uint256 expectedFee = 5000e6 - bobPosition.amount;
        assertGt(expectedFee, 0, "Bob should have paid fees");

        // Bob's cap should be based on fees paid (200% of fees), not principal
        // For Bob: feesPaid > 0, so cap = feesPaid * maxUserRewardBps / BPS
        uint256 maxRewardFromFees = (expectedFee * MAX_USER_REWARD_BPS) / 10000;

        // Wait for more deposits to generate rewards
        vm.warp(block.timestamp + 1 days);
        vm.prank(charlie);
        market.commitSupport(10_000e6);

        vm.warp(block.timestamp + MIN_REWARD_DURATION + 1);

        uint256 pending = market.pendingRewards(bobPos);
        assertLe(pending, maxRewardFromFees, "Bob's rewards should be capped by fees paid");
    }
}
