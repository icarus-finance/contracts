// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IGauge} from "./interfaces/IGauge.sol";

/// @notice Atomically adds two ERC20 tokens to a V2 pool and stakes the resulting LP.
/// @dev Deploy with the trusted protocol Router. Native assets must first be wrapped.
contract LiquidityStakeHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRouter public immutable router;
    IVoter public immutable voter;

    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 minLiquidity;
        address recipient;
        uint256 deadline;
    }

    error InvalidParams();
    error InvalidGauge();
    error UnsupportedToken();
    error InsufficientLiquidity();

    event LiquidityStaked(
        address indexed caller, address indexed recipient, address indexed pool, address gauge, uint256 liquidity
    );

    constructor(address _router) {
        if (_router.code.length == 0) revert InvalidParams();
        router = IRouter(_router);
        voter = IVoter(IRouter(_router).voter());
    }

    /// @notice Approve desired amounts to this helper before calling. Refunds go to caller.
    /// @dev Requires an existing pool with a live registered gauge. No swaps or permits.
    ///      Fee-on-transfer and rebasing tokens are unsupported.
    function addLiquidityAndStake(AddLiquidityParams calldata p)
        external
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        if (
            p.tokenA == p.tokenB || p.tokenA == address(0) || p.tokenB == address(0) || p.recipient == address(0)
                || p.recipient == address(this) || p.amountADesired == 0 || p.amountBDesired == 0
        ) revert InvalidParams();
        address pool = router.poolFor(p.tokenA, p.tokenB, p.stable, router.defaultFactory());
        address gauge = voter.gauges(pool);
        if (gauge == address(0) || !voter.isAlive(gauge) || IGauge(gauge).stakingToken() != pool) {
            revert InvalidGauge();
        }

        IERC20 tokenA = IERC20(p.tokenA);
        IERC20 tokenB = IERC20(p.tokenB);
        _pull(tokenA, p.amountADesired);
        _pull(tokenB, p.amountBDesired);
        tokenA.forceApprove(address(router), p.amountADesired);
        tokenB.forceApprove(address(router), p.amountBDesired);
        (amountA, amountB, liquidity) = router.addLiquidity(
            p.tokenA,
            p.tokenB,
            p.stable,
            p.amountADesired,
            p.amountBDesired,
            p.amountAMin,
            p.amountBMin,
            address(this),
            p.deadline
        );
        if (liquidity < p.minLiquidity) revert InsufficientLiquidity();
        tokenA.forceApprove(address(router), 0);
        tokenB.forceApprove(address(router), 0);
        IERC20(pool).forceApprove(gauge, liquidity);
        IGauge(gauge).deposit(liquidity, p.recipient);
        IERC20(pool).forceApprove(gauge, 0);
        if (p.amountADesired > amountA) tokenA.safeTransfer(msg.sender, p.amountADesired - amountA);
        if (p.amountBDesired > amountB) tokenB.safeTransfer(msg.sender, p.amountBDesired - amountB);
        emit LiquidityStaked(msg.sender, p.recipient, pool, gauge, liquidity);
    }

    function _pull(IERC20 token, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
    }
}
