pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

import "./RefundAdjudicator.sol";

// @author Patrick McCorry and Chris Buckland (PISA Research)
// @title Lockable Deposit
// @notice Handles the collateral security deposit and withdrawal process. This deposit will be locked
// - cannot be withdrawn - if the refund adjudicator transitions into a forfeitted state.
// @dev Dependency on the Refund Adjudicator contract
contract LockableDeposit {
    address payable admin;
    address public refundAdjudicator;
    uint public withdrawalPeriod;
    bool public withdrawalInitiated;
    uint public withdrawalBlock;

    event RequestWithdraw();
    event CompleteWithdraw();

    // @param _admin Authorised user to request and perform withdrawal of security deposit. (Optional: It can be a smart contract)
    // @param _refundAdjudicator External smart contract that is responsible for processing all disputes.
    // @param _withdrawalPeriod Minimum length of time the security deposit is locked into this contract.
    constructor(address payable _admin, address _refundAdjudicator, uint _withdrawalPeriod) public {
        admin = _admin;
        refundAdjudicator = _refundAdjudicator;
        withdrawalPeriod = _withdrawalPeriod;
    }

    // @dev Admin can request the security deposit to be withdrawn. Kick-starts the withdraw timer.
    function requestWithdrawal() public {
        require(msg.sender == admin, "msg.sender is not admin.");
        withdrawalInitiated = true;
        withdrawalBlock = block.number + withdrawalPeriod;
        emit RequestWithdraw();
    }

    // @dev Admin can withdraw coins once the withdrawal timer has expired.
    function withdraw() public {
        require(msg.sender == admin, "msg.sender must be admin.");
        require(withdrawalInitiated, "Withdrawal is not initiated.");
        require(block.number > withdrawalBlock, "Withdrawal block has not been reached.");
        require(!RefundAdjudicator(refundAdjudicator).forfeited(), "Refund Adjudicator has been slashed. Withdraw frozen.");
        withdrawalInitiated = false;
        withdrawalBlock = 0;

        admin.transfer(address(this).balance);
        emit CompleteWithdraw();
    }

    // @dev Security deposit can be topped up.
    function() external payable {}
}
