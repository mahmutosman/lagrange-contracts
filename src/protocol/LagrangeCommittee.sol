// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";

import "../library/HermezHelpers.sol";
import "../library/EvidenceVerifier.sol";
import "../interfaces/ILagrangeCommittee.sol";
import "../interfaces/ILagrangeService.sol";

contract LagrangeCommittee is
    Initializable,
    OwnableUpgradeable,
    HermezHelpers,
    ILagrangeCommittee
{
    ILagrangeService public immutable service;

    // Active Committee
    uint256 public constant COMMITTEE_CURRENT = 0;
    // Frozen Committee - Next "Current" Committee
    uint256 public constant COMMITTEE_NEXT_1 = 1;

    // ChainID => Address
    mapping(uint256 => address[]) public addedAddrs;
    mapping(uint256 => address[]) public removedAddrs;

    // ChainID => Committee
    mapping(uint256 => CommitteeDef) public CommitteeParams;
    // ChainID => Epoch => CommitteeData
    mapping(uint256 => mapping(uint256 => CommitteeData)) public Committees;

    /* Live Committee Data */
    // ChainID => Committee Map Length
    mapping(uint256 => uint256) public CommitteeMapLength;
    // ChainID => Committee Leaf Hash
    mapping(uint256 => uint256[]) public CommitteeMapKeys;
    // ChainID => Committee Leaf Hash => Committee Leaf
    mapping(uint256 => mapping(uint256 => CommitteeLeaf)) public CommitteeMap;
    // ChainID => Merkle Nodes
    mapping(uint256 => uint256[]) public CommitteeLeaves;

    mapping(address => OperatorStatus) public operators;

    // ChainID => Epoch check if committee tree has been updated
    mapping(uint256 => uint256) public updatedEpoch;

    // Event fired on initialization of a new committee
    event InitCommittee(
        uint256 chainID,
        uint256 duration,
        uint256 freezeDuration
    );

    // Fired on successful rotation of committee
    event UpdateCommittee(uint256 chainID, bytes32 current);

    modifier onlyService() {
        require(
            msg.sender == address(service),
            "Only service can call this function."
        );
        _;
    }

    constructor(ILagrangeService _service) {
        service = _service;
        _disableInitializers();
    }

    // Initializer: Accepts poseidon contracts for 2, 3, and 4 elements
    function initialize(
        address initialOwner,
        address _poseidon2Elements,
        address _poseidon3Elements,
        address _poseidon4Elements
    ) external initializer {
        _initializeHelpers(
            _poseidon2Elements,
            _poseidon3Elements,
            _poseidon4Elements
        );
        _transferOwnership(initialOwner);
    }

    // Initialize new committee.
    function _initCommittee(
        uint256 chainID,
        uint256 _duration,
        uint256 freezeDuration
    ) internal {
        require(
            CommitteeParams[chainID].startBlock == 0,
            "Committee has already been initialized."
        );

        CommitteeParams[chainID] = CommitteeDef(
            block.number,
            _duration,
            freezeDuration
        );
        Committees[chainID][0] = CommitteeData(0, 0, 0);

        CommitteeMapKeys[chainID] = new uint256[](0);
        CommitteeMapLength[chainID] = 0;
        CommitteeLeaves[chainID] = new uint256[](0);

        emit InitCommittee(chainID, _duration, freezeDuration);
    }

    function getServeUntilBlock(address operator) public view returns (uint32) {
        return operators[operator].serveUntilBlock;
    }

    function setSlashed(
        address operator,
        uint256 chainID,
        bool slashed
    ) public onlyService {
        operators[operator].slashed = slashed;
        removedAddrs[chainID].push(operator);
    }

    function getSlashed(address operator) public view returns (bool) {
        return operators[operator].slashed;
    }

    // Remove address from committee map for chainID, update keys and length/height
    function _removeCommitteeAddr(uint256 chainID, address addr) internal {
        for (uint256 i = 0; i < CommitteeMapKeys[chainID].length; i++) {
            uint256 _i = CommitteeMapKeys[chainID][i];
            uint256 _if = CommitteeMapKeys[chainID][
                CommitteeMapKeys[chainID].length - 1
            ];
            if (CommitteeMap[chainID][_i].addr == addr) {
                CommitteeMap[chainID][_i] = CommitteeMap[chainID][_if];
                CommitteeMap[chainID][_if] = CommitteeLeaf(address(0), 0, "");

                CommitteeMapKeys[chainID][i] = CommitteeMapKeys[chainID][
                    CommitteeMapKeys[chainID].length - 1
                ];
                CommitteeMapKeys[chainID].pop;
                CommitteeMapLength[chainID]--;
            }
        }
    }

    // Return Poseidon Hash of Committee Leaf
    function getLeafHash(
        CommitteeLeaf memory cleaf
    ) public view returns (uint256) {
        return
            _hash3Elements(
                [
                    uint256(uint160(cleaf.addr)),
                    uint256(cleaf.stake),
                    uint256(keccak256(cleaf.blsPubKey))
                ]
            );
    }

    // Add address to committee (NEXT_2) trie
    function _committeeAdd(
        uint256 chainID,
        address addr,
        uint256 stake,
        bytes memory _blsPubKey
    ) internal {
        require(
            CommitteeParams[chainID].startBlock > 0,
            "A committee for this chain ID has not been initialized."
        );

        CommitteeLeaf memory cleaf = CommitteeLeaf(addr, stake, _blsPubKey);
        uint256 lhash = getLeafHash(cleaf);
        CommitteeMap[chainID][lhash] = cleaf;
        CommitteeMapKeys[chainID].push(lhash);
        CommitteeMapLength[chainID]++;
        CommitteeLeaves[chainID].push(lhash);
    }

    // Returns chain's committee current and next roots at a given block.
    function getCommittee(
        uint256 chainID, 
        uint256 blockNumber
    ) public view returns (uint256, uint256) {
        uint256 epochNumber = getEpochNumber(chainID, blockNumber);
        uint256 nextEpoch = getEpochNumber(chainID, blockNumber + 1);
        return (Committees[chainID][epochNumber].root, Committees[chainID][nextEpoch].root);
    }

    // Computes and returns "next" committee root.
    function getNext1CommitteeRoot(
        uint256 chainID
    ) public view returns (uint256) {
        if (CommitteeLeaves[chainID].length == 0) {
            return _hash2Elements([uint256(0), uint256(0)]);
        } else if (CommitteeLeaves[chainID].length == 1) {
            return CommitteeLeaves[chainID][0];
        }

        // Calculate limit
        uint256 _lim = 2;
        while (_lim < CommitteeLeaves[chainID].length) {
            _lim *= 2;
        }
        // Sequentially hash leaves to get result.
        uint256 result = CommitteeLeaves[chainID][0];
        for (uint256 i = 1; i < _lim; i++) {
            if (i < CommitteeLeaves[chainID].length) {
                result = _hash2Elements([result, CommitteeLeaves[chainID][i]]);
            } else {
                result = _hash2Elements([result, 0]);
            }
        }

        return result;
    }

    // Recalculates committee root (next_1)
    function _compCommitteeRoot(uint256 chainID, uint256 epochNumber) internal {
        uint256 nextRoot = getNext1CommitteeRoot(chainID);

        // Update roots
        uint256 nextEpoch = epochNumber + COMMITTEE_NEXT_1;
        Committees[chainID][nextEpoch]
            .height = CommitteeMapLength[chainID];
        Committees[chainID][nextEpoch].root = nextRoot;
        Committees[chainID][nextEpoch]
            .totalVotingPower = _getTotalVotingPower(chainID);
    }

    // Initializes a new committee, and optionally associates addresses with it.
    function registerChain(
        uint256 chainID,
        uint256 epochPeriod,
        uint256 freezeDuration
    ) public onlyOwner {
        _initCommittee(chainID, epochPeriod, freezeDuration);
        _update(chainID, 0);
    }

    // Adds address stake data and flags it for committee addition
    function addOperator(
        address operator,
        uint256 chainID,
        bytes memory blsPubKey,
        uint256 stake,
        uint32 serveUntilBlock
    ) public onlyService {
        addedAddrs[chainID].push(operator);
        operators[operator] = OperatorStatus(stake, blsPubKey, serveUntilBlock, false);
    }

    function isUpdatable(
        uint256 epochNumber,
        uint256 chainID
    ) public view returns (bool) {
        uint256 epochEnd = epochNumber + CommitteeParams[chainID].duration;
        uint256 freezeDuration = CommitteeParams[chainID].freezeDuration;
        return block.number > epochEnd - freezeDuration;
    }

    // If applicable, updates committee based on staking, unstaking, and slashing.
    function update(uint256 chainID) public {
        uint256 epochNumber = getEpochNumber(chainID, block.number);

        require(
            isUpdatable(epochNumber, chainID),
            "Block number is prior to committee freeze window."
        );

        require(updatedEpoch[chainID] < epochNumber, "Already updated.");

        _update(chainID, epochNumber);
    }

    function _update(uint256 chainID, uint256 epochNumber) internal {
        for (uint256 i = 0; i < addedAddrs[chainID].length; i++) {
            address addedAddr = addedAddrs[chainID][i];
            OperatorStatus memory op = operators[addedAddr];
            _committeeAdd(
                chainID,
                addedAddr,
                op.amount,
                op.blsPubKey
            );
        }
        for (uint256 i = 0; i < removedAddrs[chainID].length; i++) {
            _removeCommitteeAddr(chainID, removedAddrs[chainID][i]);
        }

        _compCommitteeRoot(chainID, epochNumber);

        updatedEpoch[chainID] = epochNumber;

        delete addedAddrs[chainID];
        delete removedAddrs[chainID];

        emit UpdateCommittee(
            chainID,
            bytes32(Committees[chainID][epochNumber + COMMITTEE_NEXT_1].root)
        );
    }

    // Computes epoch number for a chain's committee at a given block
    function getEpochNumber(
        uint256 chainID,
        uint256 blockNumber
    ) public view returns (uint256) {
        uint256 startBlockNumber = CommitteeParams[chainID].startBlock;
        uint256 epochPeriod = CommitteeParams[chainID].duration;
        return (blockNumber - startBlockNumber) / epochPeriod + 1;
    }

    // Returns cumulative strategy shares for opted in addresses
    function _getTotalVotingPower(
        uint256 chainID
    ) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < CommitteeMapLength[chainID]; i++) {
            total += CommitteeMap[chainID][CommitteeMapKeys[chainID][i]].stake;
        }
        return total;
    }
}