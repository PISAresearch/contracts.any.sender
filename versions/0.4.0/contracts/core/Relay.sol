// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "./DataRegistry.sol";
import "./RelayTxStruct.sol";
import "../payment/PaymentDeposit.sol";

// @author PISA Research (Patrick & Chris)
// @title Relay: Executing relay transactions
// @notice This contract only handles executing relay transactions.
//         It does not have logic to handle the security deposit or proving fraud.
// @dev The operator must supply gast refund this contract as it ms relayers the cost of submitting jobs.
contract Relay is DataRegistry, RelayTxStruct, PaymentDeposit {
    mapping(address => bool) public relayers;

    event RelayExecuted(bytes32 indexed relayTxId, bool success, address indexed from, address indexed to, uint gasUsed, uint gasPrice);
    event RelayerInstalled(address relayer);
    event RelayerUninstalled(address relayer);
    event OutOfCoins();

    // @param _newOwner Owner can install relayers
    // @dev Behind the scenes, the DataRegistry is creating two shards via an internal constructor.
    function initialize(address _newOwner, uint _shardInterval) public initializer onlyOwner {
        PaymentDeposit.initialize(_newOwner);
        DataRegistry.initialize(_shardInterval);
    }

    // @param _relayTx A relay tx containing the job to execute
    // @param _gasRefund Whether the relayer requires a gas refund
    // @dev Only authorised relayer can execute relay jobs and they are refunded gas at the end of the call.
    //      Critically, if the relay job fails, we can simply catch exception and continue to record the log.
    function execute(RelayTx memory _relayTx, bool _gasRefund) public {
        uint gasStarted = gasleft();

        // The msg.sender check protects against two problems:
        // - Replay attacks across chains (chainid in transaction)
        // - Re-entrancy attacks back into .execute() (signer required)
        require(relayers[msg.sender], "Relayer must call this function.");
        require(_relayTx.relay == address(this), "Relay tx MUST be for this relay contract.");

        bytes32 relayTxId = computeRelayTxId(_relayTx);

        // Only record log if a compensation is required
        if(_relayTx.compensation != 0) {
            // Record a log of executing the job, Each shard only records the first job since the first job has the
            // earliest timestamp.
            setRecord(relayTxId, block.number);
        }

        // We do not require the customer to sign the relay tx.
        // Why? If relayer submits wrong relay tx, it wont have the correct RelayTxId.
        // So the RelayTxId won't be recorded and the customer can easily prove
        // the correct relay tx was never submitted for execution.

        // In the worst case, the contract will only send 63/64 of the transaction's
        // remaining gas due to https://eips.ethereum.org/EIPS/eip-150
        // But this is problematic as outlined in https://eips.ethereum.org/EIPS/eip-1930
        // so to fix... we need to make sure we supply 64/63 * gasLimit.
        // Assumption: Underlying contract called did not have a minimum gas required check
        // We add 1000 to cover the cost of calculating new gas limit - this should be a lot more than
        // is required - measuring shows cost of 58
        require(gasleft() > (_relayTx.gasLimit + _relayTx.gasLimit / 63) + 1000, "Not enough gas supplied.");

        // execute the actual call
        (bool success,) = _relayTx.to.call{gas: _relayTx.gasLimit}(_relayTx.data);

        // we add some gas using hard coded opcode pricing for computation that we could measure
        uint gasUsed = gasStarted - gasleft() + // execute cost
                            (msg.data.length * 16) + // data input cost (add 1 for gasRefund bool)
                            2355 + // cost of RelayExecuted event - 375 + 375 + 375 + (160 * 8)
                            21000; // transaction cost

        if (_gasRefund) {
            gasUsed += (9000 + 1000); // refund cost, send + change for calculations
            if (!payable(msg.sender).send(gasUsed*tx.gasprice)) {
                // Notify admin we need to provide more refund to this contract
                emit OutOfCoins();
            }
        }

        emit RelayExecuted(relayTxId, success, _relayTx.from, _relayTx.to, gasUsed, tx.gasprice);
    }

    // @param _relayer New relayer address
    // @dev Only the owner can install a new relayer
    function installRelayer(address _relayer) onlyOwner public {
        require(!relayers[_relayer], "Relayer is already installed.");
        require(_relayer != address(this), "The relay contract cannot be installed as a relayer.");

        relayers[_relayer] = true;
        emit RelayerInstalled(_relayer);
    }

    // @param _relayer New relayer address
    // @dev Only the owner can uninstall a new relayer
    function uninstallRelayer(address _relayer) onlyOwner public {
        require(relayers[_relayer], "Relayer must be installed.");

        relayers[_relayer] = false;
        emit RelayerUninstalled(_relayer);
    }
}
