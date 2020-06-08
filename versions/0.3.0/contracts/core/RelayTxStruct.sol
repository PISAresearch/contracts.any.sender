pragma solidity 0.6.2;
pragma experimental ABIEncoderV2;

// @author Patrick McCorry & Chris Buckland (anydot)
// @title Relay
// @notice Relay tx data structure
contract RelayTxStruct {

    // @dev The relay transaction
    struct RelayTx {
        address to; // Address for external contract
        address payable from; // Address for the user who hired the relayer
        bytes data; // Call data that we need to send. Includes function call name, etc.
        uint deadline; // Expiry block number for appointment
        uint compensation; // How much should the operator compensation the user by?
        uint gasLimit; // How much gas is allocated to this function call?
        uint chainId; // ChainID
        address relay; // The relay contract!
    }

    // @return Relay tx hash (bytes32)
    // @dev Pack the encoding when computing the ID.
    function computeRelayTxId(RelayTx memory self) public pure returns (bytes32) {
      return keccak256(abi.encode(self.to, self.from, self.data, self.deadline, self.compensation, self.gasLimit, self.chainId, self.relay));
    }
}