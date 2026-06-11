// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {WordToken} from "../src/WordToken.sol";

/// @title  Phase 3 — seal WORD minting and renounce token ownership (scanner hygiene)
/// @notice Run ONLY after: all 10,000 NFTs are minted (including the 200 admin-reserve —
///         an unminted reserve blocks the seal), the 1,000,000e18 liquidity allotment is
///         fully minted (phase 2), and the burner is wired (phase 1). Ordering is critical
///         and IRREVERSIBLE: renouncing kills setBurner and mintLiquidity forever, which is
///         exactly the point — token scanners then read owner = 0x0 with no minting paths,
///         neutralizing the "Mintable"/"owner privileges" flags (runbook, scanner hygiene #2).
///
///         Required env: WORD_TOKEN. Broadcaster must be the token admin.
contract SealAndRenounce is Script {
    function run() external {
        WordToken wordToken = WordToken(vm.envAddress("WORD_TOKEN"));

        // Hard preconditions — abort loudly rather than renounce a half-wired token.
        require(wordToken.burner() != address(0), "burner not wired");
        require(wordToken.liquidityMinted() == wordToken.LIQUIDITY_CAP(), "liquidity allotment not fully minted");
        require(wordToken.backingMinted() == wordToken.BACKING_CAP(), "NFT mint-out incomplete (incl. admin reserve)");

        vm.startBroadcast();
        if (!wordToken.mintingSealed()) {
            wordToken.sealMinting();
        }
        wordToken.renounceOwnership();
        vm.stopBroadcast();

        console2.log("WordToken sealed at:", wordToken.totalSupply());
        console2.log("Ownership renounced. owner() == address(0); supply can now only fall to the 10M floor.");
        console2.log("BUY-AND-BURN IS NOW LIVE: executeBuyback() works from this moment (SYS-1) -");
        console2.log("keepers will start spending the accrued burn slice for the 1% tip.");
    }
}
