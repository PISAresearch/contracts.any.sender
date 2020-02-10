pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

import "./Relay.sol";
import "./RelayTxStruct.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";

// @author Patrick McCorry and Chris Buckland (PISA Research)
// @title RefundAdjudicator: Fraud Proofs
// @notice We have three contracts.
// - Relay: Used by the relayer to submit responses.
//   It inherits the DataRegistry to manage temporarily storage of records.
// - RefundAdjudicators: Accepts receipts (relay transactions signed by the relayer) and handles the customer's dispute process.
//   If the relayer fails to provide a quality of service, then it must refund the customer in a timely manner.
// - LockableDeposit: Holds the relayer's security deposit. It will look up the refundadjudicator to determine
//   if the deposit should be locked or released to the relayer.
// The contracts ensure that our relayers are financially accountable and
// that evidence/logs are automatically produced for later use.
// @dev Dependency on the DataRegistry and Relayer contract
contract RefundAdjudicator is RelayTxStruct {

    using ECDSA for bytes32;

    // Forfeits external deposits when relayer fails to refund user.
    bool public forfeited;

    // NONE = No refund required,
    // PENDING = User is waiting for a refund,
    // REFUND = Refund issued by relayer,
    // RESOLVED = User has claimed refund,
    // No need for "forfeited" as there is a dedicated value defined above.
    enum RefundStatus { NONE, PENDING, REFUND, RESOLVED }

    // Given an appointment, has the refund been issued?
    // We keep it around forever - should not be that many.
    mapping(bytes32 => Refund) public refunds;

    // Required for looking up responses
    Relay public relay;
    address receiptSigner; // All receipts are signed by this key.

    // Time (blocks) to issue a refund.
    uint public refundPeriod;

    struct Refund {
        RefundStatus status; // Defaults to RefundStatus.NONE
        uint deadline; // User must be refunded by (or on) this block height
    }

    event RequestRefund(bytes32 indexed relayTxId, address user, uint refund, uint deadline);
    event RefundIssued(bytes32 indexed relayTxId, address relayer, address user, uint refund);
    event ForfeitIssued();

    // @param _relay Relay contract
    // @param _receiptSigner Receipt signer
    // @param _refundPeriod Issue refund grace period (number of blocks)
    constructor(Relay _relay, address _receiptSigner, uint _refundPeriod) public {
        relay = _relay;
        refundPeriod = _refundPeriod;
        receiptSigner = _receiptSigner;
    }

    // @param _relayTx RelayTx with the relay transaction
    // @param _sig Relayer's signature for the relay tx.
    // @Dev User can submit a receipt (relay tx + relayer sig) by the relayer and this contract will verify if the
    // relayed transaction was performed. If not, it triggers the refund process for the customer.
    function requestRefund(RelayTx memory _relayTx, bytes memory _sig) public {

        require(_relayTx.relay == address(relay), "Mismatching relay address in the relay tx.");
        require(block.number > _relayTx.deadline, "The relayer still has time to finish the job.");
        require(_relayTx.refund != 0, "No refund promised to customer in relay tx.");

        // All logs are recorded in the Relay's DataRegistry. It has two shards and each shard
        // will be used for a fixed time INTERVAL. Why? We do not want to store lots forever in Ethereum.
        // Let's consider a simple example.
        // - All records are stored in shard1 during interval T1 -> T2.
        // - All records are stored in shard2 during interval T2 -> T3.
        // - When we re-visit shard1 during interval T3 -> T4, we will DELETE the shard and RECREATE it.
        // - When we re-visit shard2 during interval T4 -> T5, we will DELETE the shard and RECREATE it.
        // So the "minimum" life-time for a record is a single interval.
        // If we set the record just before the end of T3, then it will be reset at the start of T5.
        // Thus the record only remains in Ethereum it  during T3 -> T4.

        // For us to stay secure, all receipts must satisfy the condition:
        // INTERVAL > [time for pisa to do job] + [time for customer to provide evidence]
        // So we allocate INTERVAL/2 = [time for customer to provide evidence]
        // And [time for pisa to do job] must NEVER be greater than INTERVAL/2.
        // In practice, the DataRegistry should be 120 days or more, so we are unlikely to accept a job
        // longer than 60 days to relay.
        uint intervalHalf = relay.getInterval()/2;

        // Overflow is not an issue as .deadline must be a larger number (i.e. overflowing to 1 does not benefit attack).
        require(_relayTx.deadline + intervalHalf > block.number, "Record may no longer exist in the registry.");

        // We keep a log of all successful refunds. It should be few, so lets prevent double-refunds.
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(refunds[relayTxId].status == RefundStatus.NONE, "Cannot request refund twice.");

        // Relayer must have signed and accepted the job.
        // Note: We don't need the user's signature due to how the relayTxId is constructed.
        // i.e. a relayer cannot tamper with it and if they broadcast it early they just hurt themselves.
        require(receiptSigner == relayTxId.toEthSignedMessageHash().recover(_sig), "Relayer did not sign the receipt.");

        // Look up if the relayer responded in the DataRegistry
        require(!checkDataRegistryRecord(relayTxId, _relayTx.deadline), "No refund as relay transaction was completed in time.");

        refunds[relayTxId].status = RefundStatus.PENDING;
        refunds[relayTxId].deadline = block.number + refundPeriod;

        emit RequestRefund(relayTxId, _relayTx.from, _relayTx.refund, refunds[relayTxId].deadline);
    }

    // @param _relayTxId Unique identification hash for relay tx
    // @param _deadline Expiry time from relay tx
    // @dev The DataRegistry records when the relay tx was submitted (block number).
    //      So we only care about the earliest record in a shard.
    function checkDataRegistryRecord(bytes32 _relayTxId, uint _deadline) internal view returns (bool) {
        // Look through every shard (should only be two)
        uint shards = relay.getTotalShards();
        for(uint i=0; i<shards; i++) {

            // Relay's DataRegistry only stores timestamp.
            uint response = relay.fetchRecord(i, address(relay), _relayTxId);

            // It cannot be 0 as this implies no response at all!
            if(response > 0) {

                // We should find one response before the deadline
                if(_deadline >= response) {
                    return true;
                }
            }
        }

       // No response.
       return false;
    }

    // @param _relayTx Relay tx has the refund information.
    // @dev Relayer sends refund to the user based on the refund amount set in the relay tx.
    function issueRefund(RelayTx memory _relayTx) public payable {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(refunds[relayTxId].status == RefundStatus.PENDING, "Refund record must be in PENDING mode.");
        require(_relayTx.refund == msg.value, "Relayer must refund the exact value.");
        refunds[relayTxId].status = RefundStatus.REFUND;
        emit RefundIssued(relayTxId, msg.sender, _relayTx.from, msg.value);
    }

    // @param _relayTx Relay tx has the refund information.
    // @dev User can withdraw the refund after it was issued by the relayer (in issueRefund()).
    function withdrawRefund(RelayTx memory _relayTx) public {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(refunds[relayTxId].status == RefundStatus.REFUND, "Refund record must be in REFUND mode.");
        refunds[relayTxId].status = RefundStatus.RESOLVED;
        uint toSend = _relayTx.refund;
        _relayTx.from.transfer(toSend);
    }

    // @param _relayTx Relay tx issuing forfeit
    // @dev Sets FLAG to forfeited if the relayer fails to refund the user in time.
    // Called by the user if their refund is not issued in a timely manner.
    function issueForfeit(RelayTx memory _relayTx) public {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(refunds[relayTxId].status == RefundStatus.PENDING, "RefundStatus must still be PENDING.");
        require(block.number > refunds[relayTxId].deadline, "Deadline for refund must have passed.");

        // damnation.😱
        forfeited = true;
        emit ForfeitIssued();
    }
}
