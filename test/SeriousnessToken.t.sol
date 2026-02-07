// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SeriousnessToken} from "../src/SeriousnessToken.sol";
import {ISeriousnessToken} from "../src/interfaces/ISeriousnessToken.sol";
import {BeliefVault} from "../src/BeliefVault.sol";
import {BeliefMarket} from "../src/BeliefMarket.sol";
import {MockUSDC} from "../src/mock/MockUSDC.sol";

contract SeriousnessTokenTest is Test {
    SeriousnessToken public srs;
    BeliefVault public vault;
    BeliefMarket public market;
    MockUSDC public usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();

        // This test contract acts as the factory
        vault = new BeliefVault(address(this), address(usdc));
        srs = new SeriousnessToken(address(vault));

        // Deploy and register a market
        market = new BeliefMarket();
        vault.registerMarket(address(market));
    }

    /*//////////////////////////////////////////////////////////////
                          SOULBOUND TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer_Reverts() public {
        // Mint some tokens to alice via market
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        // Transfer should revert
        vm.prank(alice);
        vm.expectRevert(ISeriousnessToken.TransferNotAllowed.selector);
        srs.transfer(bob, 50e18);
    }

    function test_TransferFrom_Reverts() public {
        // Mint some tokens to alice via market
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        // Approve bob
        vm.prank(alice);
        srs.approve(bob, 100e18);

        // TransferFrom should revert
        vm.prank(bob);
        vm.expectRevert(ISeriousnessToken.TransferNotAllowed.selector);
        srs.transferFrom(alice, bob, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_OnlyRegisteredMarket() public {
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        assertEq(srs.balanceOf(alice), 100e18);
    }

    function test_Mint_RevertsIfNotRegisteredMarket() public {
        vm.prank(alice);
        vm.expectRevert(ISeriousnessToken.NotRegisteredMarket.selector);
        srs.mint(alice, 100e18);
    }

    function test_Burn_OnlyRegisteredMarket() public {
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        vm.prank(address(market));
        srs.burn(alice, 50e18);

        assertEq(srs.balanceOf(alice), 50e18);
    }

    function test_Burn_RevertsIfNotRegisteredMarket() public {
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(ISeriousnessToken.NotRegisteredMarket.selector);
        srs.burn(alice, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                      BALANCE AND SUPPLY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint_UpdatesBalanceAndSupply() public {
        assertEq(srs.totalSupply(), 0);

        vm.prank(address(market));
        srs.mint(alice, 100e18);

        assertEq(srs.balanceOf(alice), 100e18);
        assertEq(srs.totalSupply(), 100e18);

        vm.prank(address(market));
        srs.mint(bob, 200e18);

        assertEq(srs.balanceOf(bob), 200e18);
        assertEq(srs.totalSupply(), 300e18);
    }

    function test_Burn_UpdatesBalanceAndSupply() public {
        vm.prank(address(market));
        srs.mint(alice, 100e18);

        vm.prank(address(market));
        srs.burn(alice, 100e18);

        assertEq(srs.balanceOf(alice), 0);
        assertEq(srs.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          METADATA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Name() public view {
        assertEq(srs.name(), "Seriousness");
    }

    function test_Symbol() public view {
        assertEq(srs.symbol(), "SRS");
    }

    function test_Decimals() public view {
        assertEq(srs.decimals(), 18);
    }

    function test_Vault() public view {
        assertEq(srs.vault(), address(vault));
    }
}
