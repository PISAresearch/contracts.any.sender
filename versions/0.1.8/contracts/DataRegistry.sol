pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

// @author Patrick McCorry
// @title DataShard
// @notice Stores data for a given epoch / interval.
// @dev Storage contract.
//      Associates msg.sender with a list of bytes32 (hash) -> uint (timestamp).
contract DataShard {
   uint public creationBlock;
   address payable owner; // DataRegistry Contract

   // The DataRegistry should be the owner!
   modifier onlyOwner {
       require(msg.sender == owner);
       _;
   }

   // Smart Contract Address => ID-based data storage
   mapping (address => mapping (bytes32 => uint)) records;

   // @param _blockNo Provided by the DataRegistry
   constructor() public {
       creationBlock = block.number;
       owner = msg.sender;
   }

   // @dev Destory contract (and all its entries)
   function kill() public onlyOwner {
       selfdestruct(owner);
   }

   // @returns Creation time (blocknumber) for this dataShard
   function getCreationBlock() public view returns (uint) {
       return creationBlock;
   }

   // @param _sc Smart contract address
   // @param _id Unique identifier for record
   // @returns A record (timestamp) or "0" if no record was found.
   function fetchRecord(address _sc, bytes32 _id) public view returns (uint) {
       return records[_sc][_id];
   }

   // @param _sc Smart contract address
   // @param _id Unique identifier for record
   // @param _timestamp A timestamp
   // @dev Only stores a record if it is NOT set. e.g. does not replace/update.
   //      We do not throw an exception to avoid DoS or return false to save gas.
   function setRecord(address _sc, bytes32 _id, uint _timestamp) external onlyOwner {
      if(records[_sc][_id] == 0) {
         records[_sc][_id] = _timestamp;
      }
   }
}
// @author Patrick McCorry
// @title DataShard
// @notice Manages the creation and destruction of data shards. Helps us be Ethereum Enviromentally Friendly.
// @dev In practice, we only need 2 dataShards for it to work well.
contract DataRegistry {

   // Shard ID => Address for DataShard
   mapping (uint => address) public dataShards;
   uint constant INTERVAL = 1000*6; // Approximately 6000 blocks a day
   uint constant TOTAL_SHARDS = 2; // Total number of data shards in rotation

   // @returns Number of blocks for an interval.
   function getInterval() public pure returns (uint) {
      return INTERVAL;
   }

   // @returns Number of shards in rotation.
   function getTotalShards() public pure returns (uint) {
      return TOTAL_SHARDS;
   }

   // @dev Values for interval and total_shards is hard-coded in the contract. Can be passed as constructor, but not big deal.
   constructor() internal {
     // Create the first DataShard
     dataShards[0] = address(new DataShard());
   }

   // @returns Instance of the DataShard
   // @dev Call this function periodically to delete/create data shards.
   function resetDataShard() public returns (DataShard) {
      // We need to do full loop before deleting an old shard!
      if(block.number - DataShard(dataShards[0]).getCreationBlock() >= INTERVAL*2) {
          address toDelete = dataShards[1];
          dataShards[1] = dataShards[0];
          dataShards[0] = address(new DataShard());
          DataShard(toDelete).kill();
      }
   }

   // @dev Returns the latest / most recently created data shard.
   function getLatestDataShard() public view returns (address) {
      return dataShards[0];
   }

   // @param _dataShard Index of data shard
   // @param _sc Smart contract that recorded the log
   // @param _id Unique identifier for the record
   // @returns Record data (timestamp)
   function fetchRecord(uint _dataShard, address _sc, bytes32 _id) public view returns (uint) {
       // Confirm the data shard exists so we can fetch data
      if(dataShards[_dataShard] != address(0)) {
          DataShard rc = DataShard(dataShards[_dataShard]);
          return rc.fetchRecord(_sc, _id);
      }
   }
   // @param _id Unique identifier for the record
   // @param _timestamp A timestamp
   // @dev We have integrated with the relay contract; so only relay can call it.
   function setRecord(bytes32 _id, uint _timestamp) internal  {
      // Fetch Index
      address dataShardAddr = getLatestDataShard();
      // Fetch the DataShard for this day. (It may reset it under the hood)
      DataShard rc = DataShard(dataShardAddr);
      // Update record!
      rc.setRecord(address(this), _id, _timestamp);
   }
}
