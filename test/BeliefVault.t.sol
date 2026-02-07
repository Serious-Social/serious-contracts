// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BeliefVault} from "../src/BeliefVault.sol";
import {IBeliefVault} from "../src/interfaces/IBeliefVault.sol";
import {MockUSDC} from "../src/mock/MockUSDC.sol";

contract BeliefVaultTest is Test {
    BeliefVault public vault;
    MockUSDC public usdc;

    address public factoryAddr = makeAddr("factory");
    address public market1 = makeAddr("market1");
    address public market2 = makeAddr("market2");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public nonMarket = makeAddr("nonMarket");

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(factoryAddr);
        vault = new BeliefVault(factoryAddr, address(usdc));

        // Register markets
        vm.startPrank(factoryAddr);
        vault.registerMarket(market1);
        vault.registerMarket(market2);
        vm.stopPrank();

        // Mint USDC to users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterMarket_OnlyFactory() public {
        address newMarket = makeAddr("newMarket");
        vm.prank(alice);
        vm.expectRevert(IBeliefVault.NotFactory.selector);
        vault.registerMarket(newMarket);
    }

    function test_RegisterMarket_Success() public {
        address newMarket = makeAddr("newMarket");
        vm.prank(factoryAddr);
        vault.registerMarket(newMarket);
        assertTrue(vault.isMarketRegistered(newMarket));
    }

    function test_RegisterMarket_CannotRegisterTwice() public {
        vm.prank(factoryAddr);
        vm.expectRevert(IBeliefVault.MarketAlreadyRegistered.selector);
        vault.registerMarket(market1);
    }

    function test_LockForMarket_OnlyRegisteredMarket() public {
        vm.prank(nonMarket);
        vm.expectRevert(IBeliefVault.NotRegisteredMarket.selector);
        vault.lockForMarket(alice, 1000e6);
    }

    function test_ReleaseFromMarket_OnlyRegisteredMarket() public {
        vm.prank(nonMarket);
        vm.expectRevert(IBeliefVault.NotRegisteredMarket.selector);
        vault.releaseFromMarket(alice, 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LockForMarket_PullsUSDC() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(market1);
        vault.lockForMarket(alice, amount);

        assertEq(usdc.balanceOf(alice), balanceBefore - amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(vault.marketBalance(market1), amount);
    }

    function test_ReleaseFromMarket_SendsUSDC() public {
        uint256 amount = 1000e6;

        // Lock first
        vm.prank(market1);
        vault.lockForMarket(alice, amount);

        uint256 balanceBefore = usdc.balanceOf(alice);

        // Release
        vm.prank(market1);
        vault.releaseFromMarket(alice, amount);

        assertEq(usdc.balanceOf(alice), balanceBefore + amount);
        assertEq(vault.marketBalance(market1), 0);
    }

    function test_LockForMarket_EmitsEvent() public {
        vm.prank(market1);
        vm.expectEmit(true, true, false, true);
        emit IBeliefVault.Locked(market1, alice, 1000e6);
        vault.lockForMarket(alice, 1000e6);
    }

    function test_ReleaseFromMarket_EmitsEvent() public {
        vm.prank(market1);
        vault.lockForMarket(alice, 1000e6);

        vm.prank(market1);
        vm.expectEmit(true, true, false, true);
        emit IBeliefVault.Released(market1, alice, 1000e6);
        vault.releaseFromMarket(alice, 1000e6);
    }

    function test_RegisterMarket_EmitsEvent() public {
        address newMarket = makeAddr("newMarket");
        vm.prank(factoryAddr);
        vm.expectEmit(true, false, false, false);
        emit IBeliefVault.MarketRegistered(newMarket);
        vault.registerMarket(newMarket);
    }

    /*//////////////////////////////////////////////////////////////
                        ISOLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MarketBalanceIsolation() public {
        // Market1 locks 1000
        vm.prank(market1);
        vault.lockForMarket(alice, 1000e6);

        // Market2 locks 2000
        vm.prank(market2);
        vault.lockForMarket(bob, 2000e6);

        assertEq(vault.marketBalance(market1), 1000e6);
        assertEq(vault.marketBalance(market2), 2000e6);

        // Market1 cannot release more than its balance
        vm.prank(market1);
        vm.expectRevert(IBeliefVault.InsufficientMarketBalance.selector);
        vault.releaseFromMarket(alice, 1500e6);

        // Market1 can release its own balance
        vm.prank(market1);
        vault.releaseFromMarket(alice, 1000e6);

        // Market2's balance unchanged
        assertEq(vault.marketBalance(market2), 2000e6);
    }

    function test_InsufficientMarketBalance() public {
        vm.prank(market1);
        vault.lockForMarket(alice, 500e6);

        vm.prank(market1);
        vm.expectRevert(IBeliefVault.InsufficientMarketBalance.selector);
        vault.releaseFromMarket(alice, 501e6);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseVault_BlocksLockForMarket() public {
        vm.prank(factoryAddr);
        vault.pauseVault();

        vm.prank(market1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.lockForMarket(alice, 1000e6);
    }

    function test_PauseVault_ReleaseStillWorks() public {
        // Lock first
        vm.prank(market1);
        vault.lockForMarket(alice, 1000e6);

        // Pause
        vm.prank(factoryAddr);
        vault.pauseVault();

        // Release should still work
        vm.prank(market1);
        vault.releaseFromMarket(alice, 1000e6);
        assertEq(vault.marketBalance(market1), 0);
    }

    function test_PauseVault_OnlyFactory() public {
        vm.prank(alice);
        vm.expectRevert(IBeliefVault.NotFactory.selector);
        vault.pauseVault();
    }

    function test_UnpauseVault_AllowsLockForMarket() public {
        vm.prank(factoryAddr);
        vault.pauseVault();

        vm.prank(factoryAddr);
        vault.unpauseVault();

        vm.prank(market1);
        vault.lockForMarket(alice, 1000e6);
        assertEq(vault.marketBalance(market1), 1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LockZeroAmount() public {
        vm.prank(market1);
        vault.lockForMarket(alice, 0);
        assertEq(vault.marketBalance(market1), 0);
    }

    function test_ReleaseZeroAmount() public {
        vm.prank(market1);
        vault.releaseFromMarket(alice, 0);
        assertEq(vault.marketBalance(market1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Factory() public view {
        assertEq(vault.factory(), factoryAddr);
    }

    function test_Usdc() public view {
        assertEq(address(vault.usdc()), address(usdc));
    }

    function test_IsMarketRegistered() public view {
        assertTrue(vault.isMarketRegistered(market1));
        assertTrue(vault.isMarketRegistered(market2));
        assertFalse(vault.isMarketRegistered(nonMarket));
    }
}
