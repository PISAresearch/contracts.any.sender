pragma solidity 0.6.2;
pragma experimental ABIEncoderV2;

import "./Relay.sol";
import "./RelayTxStruct.sol";
import "./ILockable.sol";
import "../imports/Initializable.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";

// @author Patrick McCorry and Chris Buckland (PISA Research)
// @title Adjudicator: Fraud Proofs
// @notice We have three contracts.
// - Relay: Used by the relayer to submit responses.
//   It inherits the DataRegistry to manage temporarily storage of records.
// - Adjudicators: Accepts receipts (relay transactions signed by the relayer) and handles the customer's dispute process.
//   If the relayer fails to provide a quality of service, then it must compensate the customer in a timely manner.
// - LockableDeposit: Holds the relayer's security deposit. It will look up the adjudicator to determine
//   if the deposit should be locked or released to the relayer.
// The contracts ensure that our relayers are financially accountable and
// that evidence/logs are automatically produced for later use.
// @dev Dependency on the DataRegistry and Relayer contract
contract Adjudicator is RelayTxStruct, ILockable, Initializable {

    using ECDSA for bytes32;

    // Lock external deposits when relayer fails to compensate the user.
    bool private locked;
    function isLocked() override public view returns(bool) {
        return locked;
    }

    // NONE = No compensation required,
    // PENDING = User is waiting for compensation,
    // COMPENSATED = Compensation issued by relayer,
    // RESOLVED = User has claimed compensation,
    // No need for "locked" as there is a dedicated value defined above.
    enum CompensationStatus { NONE, PENDING, COMPENSATED, RESOLVED }

    // Given an appointment, has the compensation been issued?
    // We keep it around forever - should not be that many.
    mapping(bytes32 => CompensationRecord) public compensationRecords;

    // Required for looking up responses
    Relay public relay;
    address public receiptSigner; // All receipts are signed by this key.

    // Time (blocks) to issue a compensation.
    uint public compensationPeriod;

    struct CompensationRecord {
        CompensationStatus status; // Defaults to CompensationStatus.NONE
        uint deadline; // User must be compensated by (or on) this block height
    }

    event RequestCompensation(bytes32 indexed relayTxId, address user, uint compensation, uint deadline);
    event CompensationIssued(bytes32 indexed relayTxId, address relayer, address user, uint compensation);
    event Locked();

    // @param _relay Relay contract
    // @param _receiptSigner Receipt signer
    // @param _compensationPeriod Issue compensation grace period (number of blocks)
    function initialize(Relay _relay, address _receiptSigner, uint _compensationPeriod) initializer public {
        relay = _relay;
        compensationPeriod = _compensationPeriod;
        receiptSigner = _receiptSigner;
    }
    
    // @param _relayTx RelayTx with the relay transaction
    // @param _sig Relayer's signature for the relay tx.
    // @Dev User can submit a receipt (relay tx + relayer sig) by the relayer and this contract will verify if the
    // relayed transaction was performed. If not, it triggers the compensation process for the customer.
    function requestCompensation(RelayTx memory _relayTx, bytes memory _sig) public {

        require(_relayTx.relay == address(relay), "Mismatching relay address in the relay tx.");
        require(block.number > _relayTx.deadline, "The relayer still has time to finish the job.");
        require(_relayTx.compensation != 0, "No compensation promised to customer in relay tx.");

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

        // We keep a log of all successful compensation records. It should be few, so lets prevent double-compensation.
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(compensationRecords[relayTxId].status == CompensationStatus.NONE, "Cannot request compensation twice.");

        // Relayer must have signed and accepted the job.
        // Note: We don't need the user's signature due to how the relayTxId is constructed.
        // i.e. a relayer cannot tamper with it and if they broadcast it early they just hurt themselves.
        require(receiptSigner == relayTxId.toEthSignedMessageHash().recover(_sig), "Relayer did not sign the receipt.");

        // Look up if the relayer responded in the DataRegistry
        require(!checkDataRegistryRecord(relayTxId, _relayTx.deadline), "No compensation as relay transaction was completed in time.");

        compensationRecords[relayTxId].status = CompensationStatus.PENDING;
        compensationRecords[relayTxId].deadline = block.number + compensationPeriod;

        emit RequestCompensation(relayTxId, _relayTx.from, _relayTx.compensation, compensationRecords[relayTxId].deadline);
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

    // @param _relayTx Relay tx has the compensation information.
    // @dev Relayer sends compensation to the user based on the compensation amount set in the relay tx.
    function issueCompensation(RelayTx memory _relayTx) public payable {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(compensationRecords[relayTxId].status == CompensationStatus.PENDING, "Compensation record must be in PENDING mode.");
        require(_relayTx.compensation == msg.value, "Relayer must compensate the exact value.");
        compensationRecords[relayTxId].status = CompensationStatus.COMPENSATED;
        emit CompensationIssued(relayTxId, msg.sender, _relayTx.from, msg.value);
    }

    // @param _relayTx Relay tx has the compensation information.
    // @dev User can withdraw the compensation after it was issued by the relayer (in issueCompensation()).
    function withdrawCompensation(RelayTx memory _relayTx) public {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(compensationRecords[relayTxId].status == CompensationStatus.COMPENSATED, "Compensation record must be in COMPENSATED mode.");
        compensationRecords[relayTxId].status = CompensationStatus.RESOLVED;
        uint toSend = _relayTx.compensation;
        _relayTx.from.transfer(toSend);
    }

    // @param _relayTx Relay tx to lock this adjudicator
    // Called by the user if their compensation is not issued in a timely manner.
    function lock(RelayTx memory _relayTx) public {
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        require(compensationRecords[relayTxId].status == CompensationStatus.PENDING, "CompensationStatus must still be PENDING.");
        require(block.number > compensationRecords[relayTxId].deadline, "Deadline for compensation must have passed.");

        // damnation.😱
        locked = true;
        emit Locked();
    }
}
