pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

import "./DataRegistry.sol";
import "./RelayTxStruct.sol";
import "./PaymentDeposit.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";

// @author PISA Research (Patrick & Chris)
// @title Relay: Executing relay transactions
// @notice This contract only handles executing relay transactions.
//         It does not have logic to handle the security deposit or proving fraud.
// @dev The operator must supply gast refund this contract as it ms relayers the cost of submitting jobs.
contract Relay is DataRegistry, RelayTxStruct, PaymentDeposit {

    using ECDSA for bytes32;

    mapping(address => bool) public relayers;

    address public admin;

    event RelayExecuted(bytes32 indexed relayTxId, bool success, address from, uint gasUsed, uint gasPrice);
    event RelayerInstalled(address relayer);
    event RelayerUninstalled(address relayer);
    event GasRefund(uint val);
    event OutOfCoins();

    // @param _admin Admin can install relayers
    // @dev Behind the scenes, the DataRegistry is creating two shards via an internal constructor.
    constructor(address _admin) PaymentDeposit(_admin) public {
        admin = _admin;
    }

    // @param _relayTx A relay tx containing the job to execute
    // @dev Only authorised relayer can execute relay jobs and they are refunded at the end of the call.
    //      Critically, if the relay job fails, we can simply catch exception and continue to record the log.
    function execute(RelayTx memory _relayTx) public {
        uint gasStarted = gasleft();

        require(relayers[msg.sender], "Relayer must call this function.");
        require(_relayTx.relay == address(this), "Relay tx MUST be for this relay contract.");

        // We do not require the customer to sign the relay tx.
        // Why? If relayer submits wrong relay tx, it wont have the correct RelayTxId.
        // So the RelayTxId won't be recorded and the customer can easily prove
        // the correct relay tx was never submitted for execution.

        // In the worst case, the contract will only send 63/64 of the transaction's
        // remaining gas due to https://eips.ethereum.org/EIPS/eip-150
        // But this is problematic as outlined in https://eips.ethereum.org/EIPS/eip-1930
        // so to fix... we need to make sure all the gas is supplied correctly.
        (bool success,) = _relayTx.to.call.gas(_relayTx.gasLimit)(_relayTx.data);
        // Assumption: Underlying contract called did not have a minimum gas required check
        require(gasleft() > _relayTx.gasLimit / 63, "Gas limit for relay transaction was not respected by relayer.");

        // Only record log if a refund is required
        bytes32 relayTxId = computeRelayTxId(_relayTx);
        if(_relayTx.refund != 0) {
            // Record a log of executing the job.
            // Each shard only records the FIRST job.
            // Why? It has the EARLIEST timestamp.
            setRecord(relayTxId, block.number);
        }

        uint gasUsed = gasStarted - gasleft() + // execute cost
                            (abi.encode(_relayTx).length * 68) + // data input cost
                            1655 + // cost of RelayExecuted event - 375 + (160 * 8)
                            21000 + // transaction cost
                            9000; // relay gas refund cost

        // Notify admin we need to provide more redund this contract
        if(!msg.sender.send(gasUsed*tx.gasprice)) {
            emit OutOfCoins();
        }

        emit RelayExecuted(relayTxId, success, _relayTx.from, gasUsed, tx.gasprice);
    }

    // @param _relayer New relayer address
    // @param _expiry Must be installed by this time
    // @param _sig Admin's signature
    // @dev Only the admin can install a new relayer
    function installRelayer(address _relayer, uint _expiry, bytes memory _sig) public {
        require(!relayers[_relayer], "Relayer is already installed.");
        require(_expiry > block.number, "Relayer installation time has expired.");
        require(_relayer != address(this), "The relay contract cannot be installed as a relayer.");

        bytes32 sigHash = keccak256(abi.encode("install", _relayer, _expiry, address(this)));
        require(admin == sigHash.toEthSignedMessageHash().recover(_sig), "Installation not signed by admin.");

        relayers[_relayer] = true;
        emit RelayerInstalled(_relayer);
    }

    // @param _relayer New relayer address
    // @param _expiry Must be Uninstalled by this time
    // @param _sig Admin's signature
    // @dev Only the admin can uninstall a new relayer
    function uninstallRelayer(address _relayer, uint _expiry, bytes memory _sig) public {
        require(relayers[_relayer], "Relayer must be installed.");
        require(_expiry > block.number, "Relayer uninstallation time has expired.");

        bytes32 sigHash = keccak256(abi.encode("uninstall", _relayer, _expiry, address(this)));
        require(admin == sigHash.toEthSignedMessageHash().recover(_sig), "Uninstallation not signed by admin.");

        relayers[_relayer] = false;
        emit RelayerUninstalled(_relayer);
    }

    // @Dev Accepts funds to refund relayers
    function supplyGasRefund() external payable {
        require(msg.value > 0, "No value provided to supplyGasRefund.");
        emit GasRefund(msg.value);
    }

    function hasRelayer(address _relayer) public view returns (bool) {
        return relayers[_relayer];
    }
}
