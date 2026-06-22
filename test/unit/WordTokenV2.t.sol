// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WordTokenV2} from "../../src/WordTokenV2.sol";

/// @notice Unit suite for the relaunch WORD token: fixed supply, vanilla ERC-20, EIP-2612 permit.
contract WordTokenV2Test is Test {
    WordTokenV2 token;
    address recipient = makeAddr("recipient");

    function setUp() public {
        token = new WordTokenV2(recipient);
    }

    function test_metadata() public view {
        assertEq(token.name(), "WORD");
        assertEq(token.symbol(), "WORD");
        assertEq(token.decimals(), 18);
    }

    function test_entireSupplyMintedToRecipient() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000e18);
        assertEq(token.totalSupply(), 1_000_000e18);
        assertEq(token.balanceOf(recipient), 1_000_000e18);
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(WordTokenV2.ZeroAddress.selector);
        new WordTokenV2(address(0));
    }

    function test_noMintPathExists() public view {
        // No mint/owner surface: supply is forever the constructor amount. (Compile-time
        // guarantee — there is no external mint function; this asserts the invariant value.)
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    function test_transfer() public {
        address bob = makeAddr("bob");
        vm.prank(recipient);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(recipient), 1_000_000e18 - 1_000e18);
    }

    function test_transferInsufficientReverts() public {
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1)
        );
        token.transfer(recipient, 1);
    }

    function test_permitSetsAllowance() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        // Fund the permit owner so the allowance is meaningful.
        vm.prank(recipient);
        token.transfer(owner, 500e18);

        address spender = makeAddr("spender");
        uint256 value = 500e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), nonce + 1);
    }
}
