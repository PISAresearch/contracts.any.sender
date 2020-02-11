pragma solidity 0.5.11;

// @author PISA Research (Patrick & Chris)
// @title Payment Deposit: Accept payments from customers
contract PaymentDeposit {
    address owner;

    // We index the sender so that it's easy to look up all deposits
    // from a given sender.
    event Deposit(address indexed sender, uint amount);

    constructor(address _owner) public {
        owner = _owner;
    }

    /**
     * Supply a deposit for a specified recipient
     */
    function depositFor(address recipient) public payable { 
        require(msg.value > 0, "No value provided to depositFor.");
        emit Deposit(recipient, msg.value);
    }

    /**
     * As with the fallback, supply a deposit for msg.sender
     */
    function deposit() public payable {
        require(msg.value > 0, "No value provided to deposit.");
        emit Deposit(msg.sender, msg.value);
    }

    function() external payable {
        require(msg.value > 0, "No value provided to fallback.");
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * Move funds out of the contract
     */
    function send(address payable recipient, uint amount) public {
        require(msg.sender == owner, "Only the owner can send funds.");
        recipient.transfer(amount);
    }
}