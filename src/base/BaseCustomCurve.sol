// SPDX-License-Identifier: MIT
// OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/base/BaseCustomCurve.sol)

pragma solidity ^0.8.24;

import {BaseCustomAccounting} from "src/base/BaseCustomAccounting.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "src/lib/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @dev Base implementation for custom curves, inheriting from {BaseCustomAccounting}.
 *
 * This hook allows to implement a custom curve (or any logic) for swaps, which overrides the default v3-like
 * concentrated liquidity implementation of the `PoolManager`. During a swap, the hook calls the
 * {_getAmountOutFromExactInput} or {_getAmountInForExactOutput} function to calculate the amount of tokens
 * to be taken or settled. The return delta created from this calculation is then consumed and applied by the
 * `PoolManager`.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseCustomCurve is BaseCustomAccounting {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    struct CallbackDataCustom {
        address sender;
        int128 amount0;
        int128 amount1;
    }

    /**
     * @dev Set the pool `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager) {}

    /**
     * @dev Defines how the liquidity modification data is encoded and returned
     * for an add liquidity request.
     */
    function _getAddLiquidity(uint160, AddLiquidityParams memory params)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 liquidity) = _getAmountIn(params);
        return (abi.encode(amount0.toInt128(), amount1.toInt128()), liquidity);
    }

    /**
     * @dev Defines how the liquidity modification data is encoded and returned
     * for a remove liquidity request.
     */
    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        override
        returns (bytes memory, uint256)
    {
        (uint256 amount0, uint256 amount1, uint256 liquidity) = _getAmountOut(params);
        return (abi.encode(-amount0.toInt128(), -amount1.toInt128()), liquidity);
    }

    /**
     * @dev Overides the default swap logic of the `PoolManager` and calls the
     * {_getAmountOutFromExactInput} or {_getAmountInForExactOutput} function to calculate
     * the amount of tokens to be taken or settled.
     *
     * NOTE: In order to take and settle tokens from the pool, the hook must hold the liquidity added
     * via the {addLiquidity} function.
     */
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Determine if the swap is exact input or exact output
        bool exactInput = params.amountSpecified < 0;

        // Determine which currency is specified and which is unspecified
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Get the positive specified amount
        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Get the amount of the unspecified currency to be taken or settled
        uint256 unspecifiedAmount = _getAmount(
            specifiedAmount,
            exactInput ? specified : unspecified,
            exactInput ? unspecified : specified,
            params.zeroForOne,
            exactInput
        );

        // New delta must be returned, so store in memory
        BeforeSwapDelta returnDelta;

        if (exactInput) {
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            // On exact input, amount0 is specified and amount1 is unspecified.
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);

            // On exact output, amount1 is specified and amount0 is unspecified.
            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    /**
     * @dev Overides the custom accounting logic to support the custom curve integer amounts.
     *
     * @param params The parameters for the liquidity modification, encoded in the
     * {_getAddLiquidity} or {_getRemoveLiquidity} function.
     * @return delta The balance delta of the liquidity modification from the `PoolManager`.
     */
    function _modifyLiquidity(bytes memory params) internal virtual override returns (BalanceDelta delta) {
        (int128 amount0, int128 amount1) = abi.decode(params, (int128, int128));
        delta =
            abi.decode(poolManager.unlock(abi.encode(CallbackDataCustom(msg.sender, amount0, amount1))), (BalanceDelta));
    }

    /**
     * @dev Decodes the callback data and applies the liquidity modification, overriding the custom
     * accounting logic to mint and burn ERC-6909 claim tokens which are used in swaps.
     *
     * @param rawData The callback data encoded in the {_modifyLiquidity} function.
     * @return delta The balance delta of the liquidity modification from the `PoolManager`.
     */
    function _unlockCallback(bytes calldata rawData) internal virtual override returns (bytes memory) {
        CallbackDataCustom memory data = abi.decode(rawData, (CallbackDataCustom));

        int128 amount0 = 0;
        int128 amount1 = 0;

        // If liquidity amount is negative, remove liquidity from the pool. Otherwise, add liquidity to the pool.
        // When removing liquidity, burn ERC-6909 claim tokens and transfer tokens from pool to receiver.
        // When adding liquidity, mint ERC-6909 claim tokens and transfer tokens from receiver to pool.

        if (data.amount0 < 0) {
            poolKey.currency0.settle(poolManager, address(this), uint256(int256(-data.amount0)), true);
            poolKey.currency0.take(poolManager, data.sender, uint256(int256(-data.amount0)), false);
            amount0 = data.amount0;
        }

        if (data.amount1 < 0) {
            poolKey.currency1.settle(poolManager, address(this), uint256(int256(-data.amount1)), true);
            poolKey.currency1.take(poolManager, data.sender, uint256(int256(-data.amount1)), false);
            amount1 = data.amount1;
        }

        if (data.amount0 > 0) {
            poolKey.currency0.settle(poolManager, data.sender, uint256(int256(data.amount0)), false);
            poolKey.currency0.take(poolManager, address(this), uint256(int256(data.amount0)), true);
            amount0 = -data.amount0;
        }

        if (data.amount1 > 0) {
            poolKey.currency1.settle(poolManager, data.sender, uint256(int256(data.amount1)), false);
            poolKey.currency1.take(poolManager, address(this), uint256(int256(data.amount1)), true);
            amount1 = -data.amount1;
        }

        return abi.encode(toBalanceDelta(amount0, amount1));
    }

    /**
     * @dev Calculate the amount of tokens to be taken or settled from the swapper, depending on the swap
     * direction.
     *
     * @param amountIn The amount of tokens to be taken or settled.
     * @param input The input currency.
     * @param output The output currency.
     * @param zeroForOne Indicator of the swap direction.
     * @param exactInput True if the swap is exact input, false if exact output.
     * @return amount The amount of tokens to be taken or settled.
     */
    function _getAmount(uint256 amountIn, Currency input, Currency output, bool zeroForOne, bool exactInput)
        internal
        virtual
        returns (uint256 amount)
    {
        return exactInput
            ? _getAmountOutFromExactInput(amountIn, input, output, zeroForOne)
            : _getAmountInForExactOutput(amountIn, input, output, zeroForOne);
    }

    /**
     * @dev Calculate the amount of tokens to be received by the swapper from an exact input amount.
     */
    function _getAmountOutFromExactInput(uint256 amountIn, Currency input, Currency output, bool zeroForOne)
        internal
        virtual
        returns (uint256 amountOut);

    /**
     * @dev Calculate the amount of tokens to be taken from the swapper for an exact output amount.
     */
    function _getAmountInForExactOutput(uint256 amountOut, Currency input, Currency output, bool zeroForOne)
        internal
        virtual
        returns (uint256 amountIn);

    /**
     * @dev Calculate the amount of tokens to use and liquidity units to burn for a remove liquidity request.
     */
    function _getAmountOut(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /**
     * @dev Calculate the amount of tokens to use and liquidity units to mint for an add liquidity request.
     */
    function _getAmountIn(AddLiquidityParams memory params)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    /**
     * @dev Set the hook permissions, specifically `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`,
     * `beforeSwap`, and `beforeSwapReturnDelta`
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
