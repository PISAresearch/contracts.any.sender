pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

// @author Patrick McCorry & Chris Buckland (PISA Research)
// @title Relay
// @notice Relay tx data structure
contract RelayTxStruct {

    // @dev The relay transaction
    struct RelayTx {
        address to; // Address for external contract
        address payable from; // Address for the user who hired the relayer
        bytes data; // Call data that we need to send. Includes function call name, etc.
        uint deadline; // Expiry block number for appointment
        uint refund; // How much should the operator refund the user by?
        uint gasLimit; // How much gas is allocated to this function call?
        address relay; // The relay contract!
    }

    // @return Relay tx hash (bytes32)
    // @dev Pack the encoding when computing the ID.
    function computeRelayTxId(RelayTx memory self) public pure returns (bytes32) {
      return keccak256(abi.encode(self.to, self.from, self.data, self.deadline, self.refund, self.gasLimit, self.relay));
    }
}