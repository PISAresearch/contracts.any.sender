pragma solidity 0.6.2;

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "../imports/Initializable.sol";

// @author PISA Research (Patrick & Chris)
// @title Payment Deposit: Accept payments from customers
contract PaymentDeposit is Initializable, Ownable {
    // We index the sender so that it's easy to look up all deposits
    // from a given sender.
    event Deposit(address indexed sender, uint amount);

    // We index the sender so that it's easy to look up all withdraws
    // from a given sender.
    event Withdraw(address indexed sender, uint amount);
    
    // Two-step deployment process. 
    function initialize(address _newOwner) internal initializer onlyOwner {
        _transferOwnership(_newOwner);
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

    receive() external payable {
        require(msg.value > 0, "No value provided to fallback.");
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * Move funds out of the contract
     */
    function send(address payable recipient, uint amount) onlyOwner public {
        recipient.transfer(amount);
        emit Withdraw(recipient, amount);
    }

    /**
     * Use admin privileges to migrate a user's deposits to another deposit contract
     */
    function migrate(address payable recipient, uint amount, PaymentDeposit otherDeposit) onlyOwner public {
        require(address(this).balance >= amount, "Not enough balance to migrate.");
        otherDeposit.depositFor.value(amount)(recipient);
        emit Withdraw(recipient, amount);
    }
}