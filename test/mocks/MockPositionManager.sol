// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Strict PositionManager stand-in for LPLocker unit tests (agent 5).
///
///         The pinned v4-periphery expects a newer v4-core than the repo's top-level pin
///         (`PoolOperation.sol` split), so the real PositionManager implementation cannot
///         compile here; the locker's only V4 surface is one `modifyLiquidities` calldata
///         blob, which this mock decodes and STRICTLY validates instead:
///           - exactly two actions: DECREASE_LIQUIDITY then TAKE_PAIR;
///           - the decrease's liquidity delta MUST be zero (anything else reverts loudly —
///             that would be a principal withdrawal);
///           - TAKE_PAIR's recipient receives the configured pending fee amounts.
///         Real-PositionManager coverage belongs to agent 6's fork tests and the testnet
///         rehearsal in the deploy runbook.
contract MockPositionManager is ERC721 {
    error WrongActions();
    error NonZeroLiquidityDecrease(uint256 liquidity);
    error EthTransferFailed();

    PoolKey public poolKey;
    uint128 public positionLiquidity;
    uint256 public pendingFees0; // native ETH side
    uint256 public pendingFees1; // ERC20 side
    uint256 public collectCalls;

    constructor() ERC721("MockPosm", "POSM") {}

    receive() external payable {}

    function mint(address to, uint256 tokenId, PoolKey calldata key, uint128 liquidity) external {
        poolKey = key;
        positionLiquidity = liquidity;
        _mint(to, tokenId);
    }

    /// @dev Tests fund the mock with ETH/tokens and declare them as pending fees.
    function setPendingFees(uint256 fees0, uint256 fees1) external {
        pendingFees0 = fees0;
        pendingFees1 = fees1;
    }

    function getPoolAndPositionInfo(uint256) external view returns (PoolKey memory, PositionInfo) {
        return (poolKey, PositionInfo.wrap(0));
    }

    function getPositionLiquidity(uint256) external view returns (uint128) {
        return positionLiquidity;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));

        if (
            actions.length != 2 || uint8(actions[0]) != uint8(Actions.DECREASE_LIQUIDITY)
                || uint8(actions[1]) != uint8(Actions.TAKE_PAIR)
        ) revert WrongActions();

        (, uint256 liquidity,,,) = abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        if (liquidity != 0) revert NonZeroLiquidityDecrease(liquidity);

        (,, address recipient) = abi.decode(params[1], (Currency, Currency, address));

        collectCalls += 1;
        uint256 fees0 = pendingFees0;
        uint256 fees1 = pendingFees1;
        pendingFees0 = 0;
        pendingFees1 = 0;
        if (fees0 > 0) {
            (bool ok,) = recipient.call{value: fees0}("");
            if (!ok) revert EthTransferFailed();
        }
        if (fees1 > 0) {
            IERC20Minimal(Currency.unwrap(poolKey.currency1)).transfer(recipient, fees1);
        }
    }
}
