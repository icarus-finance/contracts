// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Optional callback registered globally by the team on Voter.
interface IClaimHook {
    /// @notice Called after a nonzero reward claim has settled.
    /// @dev Implementations must check msg.sender == gauge and authenticate it as an authorized gauge.
    ///      Callback reverts are ignored by gauges; settled claims and locks remain intact.
    /// @param tokenId Resulting veNFT id, or zero for a liquid IRS claim.
    /// @param amountLocked IRS deposited into escrow, or zero for a liquid claim.
    /// @param account User whose rewards were claimed.
    /// @param gauge Gauge settling the claim and invoking this callback.
    function onClaim(uint256 tokenId, uint256 amountLocked, address account, address gauge) external;
}
