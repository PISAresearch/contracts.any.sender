// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

/**
 * Interface for a contract that can be locked
 */
interface ILockable {
    /**
     * This contract considers itself to be in a "locked" state
     */
    function isLocked() external view returns(bool);
}