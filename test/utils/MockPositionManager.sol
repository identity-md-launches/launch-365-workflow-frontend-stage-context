// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @notice Minimal stand-in for Uniswap's PositionManager, reproducing the two facts the hook
/// depends on: the PositionManager is the `sender` of every liquidity callback, and it uses the NFT
/// tokenId as the position salt, so every NFT is its own position key. Mint, increase, decrease,
/// burn and collect (delta 0) go through `PoolManager.modifyLiquidity` with the same delta shapes as
/// the real contract. Settlement is simplified (direct transferFrom / msg.value instead of Permit2).
contract MockPositionManager is IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    enum Action {
        Mint,
        Increase,
        Decrease,
        Burn,
        Collect
    }

    struct CallbackData {
        Action action;
        address payer;
        uint256 tokenId;
        int256 liquidityDelta;
    }

    struct PositionData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    IPoolManager public immutable poolManager;
    uint256 public nextTokenId = 1;
    mapping(uint256 tokenId => address) public ownerOf;
    mapping(uint256 tokenId => PositionData) internal _positions;

    error NotPoolManager();
    error NotOwner(uint256 tokenId);

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    modifier onlyOwner(uint256 tokenId) {
        if (ownerOf[tokenId] != msg.sender) revert NotOwner(tokenId);
        _;
    }

    function positionOf(uint256 tokenId) external view returns (PoolKey memory key, int24 tickLower, int24 tickUpper) {
        PositionData memory p = _positions[tokenId];
        return (p.key, p.tickLower, p.tickUpper);
    }

    /// @notice The position's current liquidity as the PoolManager records it.
    function liquidityOf(uint256 tokenId) public view returns (uint128 liquidity) {
        PositionData memory p = _positions[tokenId];
        (liquidity,,) =
            poolManager.getPositionInfo(p.key.toId(), address(this), p.tickLower, p.tickUpper, bytes32(tokenId));
    }

    /// @notice The salt the PositionManager uses for `tokenId`.
    function saltOf(uint256 tokenId) external pure returns (bytes32) {
        return bytes32(tokenId);
    }

    function mint(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 liquidity, address recipient)
        external
        payable
        returns (uint256 tokenId, BalanceDelta delta)
    {
        tokenId = nextTokenId++;
        ownerOf[tokenId] = recipient;
        _positions[tokenId] = PositionData({key: key, tickLower: tickLower, tickUpper: tickUpper});
        delta = _run(CallbackData(Action.Mint, msg.sender, tokenId, int256(liquidity)));
    }

    function increase(uint256 tokenId, uint256 liquidity) external payable onlyOwner(tokenId) returns (BalanceDelta) {
        return _run(CallbackData(Action.Increase, msg.sender, tokenId, int256(liquidity)));
    }

    function decrease(uint256 tokenId, uint256 liquidity) external onlyOwner(tokenId) returns (BalanceDelta) {
        return _run(CallbackData(Action.Decrease, msg.sender, tokenId, -int256(liquidity)));
    }

    /// @notice Fee collection: a modifyLiquidity with liquidityDelta == 0.
    function collect(uint256 tokenId) external onlyOwner(tokenId) returns (BalanceDelta) {
        return _run(CallbackData(Action.Collect, msg.sender, tokenId, 0));
    }

    /// @notice Removes all remaining liquidity and destroys the NFT.
    function burn(uint256 tokenId) external onlyOwner(tokenId) returns (BalanceDelta delta) {
        uint256 liquidity = liquidityOf(tokenId);
        delta = _run(CallbackData(Action.Burn, msg.sender, tokenId, -int256(liquidity)));
        delete ownerOf[tokenId];
        delete _positions[tokenId];
    }

    function _run(CallbackData memory data) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.unlock(abi.encode(data)), (BalanceDelta));
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(data.payer, ethLeft);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory data = abi.decode(raw, (CallbackData));
        PositionData memory p = _positions[data.tokenId];

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: data.liquidityDelta,
                salt: bytes32(data.tokenId)
            }),
            ""
        );

        _settle(p.key.currency0, data.payer, delta.amount0());
        _settle(p.key.currency1, data.payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address user, int128 amount) internal {
        if (amount < 0) currency.settle(poolManager, user, uint128(-amount), false);
        else if (amount > 0) currency.take(poolManager, user, uint128(amount), false);
    }

    receive() external payable {}
}
