// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title  WordTokenV2 — standalone WORD ERC-20 (the relaunch token)
/// @author WORDBANK — https://wordbank.fun
/// @notice The original WORD was minted by and bonded to the word NFTs, so unbinding an NFT
///         released fresh WORD straight into sell pressure on the pool. This relaunch token is
///         DELIBERATELY decoupled: a plain, fixed-supply ERC-20 with no NFT bonding, no
///         backing-floor logic, no minter, and no owner. The entire 1,000,000-token supply is
///         minted once to the deployer at construction and used to seed the new WORD/ETH pool —
///         the only way to acquire it is buying that pool. Value accrues to holders by STAKING
///         (see WordStaking), funded by 50% of the pool's 1% fee; there is no token emission.
/// @dev    ERC-20 Permit is included so a holder can approve the staking contract gaslessly
///         (EIP-2612). Vanilla otherwise: no transfer hooks, no fee-on-transfer. Symbol/name
///         reuse "WORD" by design (brand continuity); the old token is abandoned, so verify by
///         contract address.
contract WordTokenV2 is ERC20, ERC20Permit {
    /// @notice The fixed total supply, minted in full at deployment. No further minting exists.
    uint256 public constant TOTAL_SUPPLY = 1_000_000e18;

    /// @notice Zero address given where a real recipient is required.
    error ZeroAddress();

    /// @param recipient The address that receives the entire supply (the deployer, which then
    ///        seeds the WORD/ETH pool with it). There is no other mint path, ever.
    constructor(address recipient) ERC20("WORD", "WORD") ERC20Permit("WORD") {
        if (recipient == address(0)) revert ZeroAddress();
        _mint(recipient, TOTAL_SUPPLY);
    }
}
