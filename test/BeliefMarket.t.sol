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
            yieldBearingEscrow: false
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

        // First staker with huge amount to hit fee cap
        vm.prank(alice);
        market.commitSupport(50_000e6);

        // Mint more for bob to test cap
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(bob);
        market.commitSupport(500_000e6);

        // Fee should be capped at max
        uint256 currentFee = market.getCurrentEntryFeeBps();
        assertEq(currentFee, LATE_ENTRY_FEE_MAX_BPS);
    }

    function test_Commit_RevertOnZeroAmount() public {
        _initializeMarket();

        vm.prank(alice);
        vm.expectRevert(IBeliefMarket.ZeroAmount.selector);
        market.commitSupport(0);
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

    function test_MultipleCheckpoints() public {
        _initializeMarket();

        // First staker
        vm.prank(alice);
        market.commitSupport(10_000e6);

        // Multiple late entries create multiple checkpoints
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        market.commitSupport(5_000e6);

        vm.warp(block.timestamp + 1 days);
        vm.prank(charlie);
        market.commitOppose(5_000e6);

        assertEq(market.getCheckpointCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CommitAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1e6, 10_000_000e6); // $1 to $10M
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
        supportAmount = bound(supportAmount, 1e6, 1_000_000e6);
        opposeAmount = bound(opposeAmount, 1e6, 1_000_000e6);
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
        totalPrincipal = bound(totalPrincipal, 1e6, 100_000_000e6); // $1 to $100M
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
}
