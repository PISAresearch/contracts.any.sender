pragma solidity 0.6.2;

/**
 * Interface for a contract that can be locked
 */
interface ILockable {
    /**
     * This contract considers itself to be in a "locked" state
     */
    function isLocked() external view returns(bool);
}