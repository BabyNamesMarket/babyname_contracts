// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

contract MarketValidation {
    address public immutable predictionMarket;

    mapping(uint8 => bytes32) public namesMerkleRoot;
    mapping(bytes32 => bool) public approvedNames;
    mapping(bytes32 => bool) public proposedNames;
    mapping(bytes32 => bool) public validRegions;
    mapping(bytes32 => bool) internal invalidRegions;
    bool public defaultRegionsSeeded;

    event NamesMerkleRootUpdated(uint8 indexed gender, bytes32 oldRoot, bytes32 newRoot);
    event NameApproved(string name, uint8 indexed gender);
    event NameProposed(string name, uint8 indexed gender, address indexed proposer);
    event DefaultRegionsSeeded();
    event RegionAdded(string region);
    event RegionRemoved(string region);

    error InvalidName();
    error DefaultRegionsAlreadySeeded();
    error NotPredictionMarket();

    modifier onlyPredictionMarket() {
        if (msg.sender != predictionMarket) revert NotPredictionMarket();
        _;
    }

    constructor(address predictionMarket_) {
        predictionMarket = predictionMarket_;
    }

    function setNamesMerkleRoot(uint8 gender, bytes32 root) external onlyPredictionMarket {
        emit NamesMerkleRootUpdated(gender, namesMerkleRoot[gender], root);
        namesMerkleRoot[gender] = root;
    }

    function approveName(string calldata name, uint8 gender) external onlyPredictionMarket {
        if (!_isAsciiLowercaseLetters(name)) revert InvalidName();
        bytes32 nameHash = _nameKey(name, gender);
        approvedNames[nameHash] = true;
        proposedNames[nameHash] = false;
        emit NameApproved(name, gender);
    }

    function proposeName(string calldata name, uint8 gender, address proposer) external onlyPredictionMarket {
        if (!_isAsciiLowercaseLetters(name)) revert InvalidName();
        bytes32 nameHash = _nameKey(name, gender);
        proposedNames[nameHash] = true;
        emit NameProposed(name, gender, proposer);
    }

    function seedDefaultRegions() external onlyPredictionMarket {
        if (defaultRegionsSeeded) revert DefaultRegionsAlreadySeeded();
        defaultRegionsSeeded = true;
        emit DefaultRegionsSeeded();
    }

    function addRegion(string calldata region) external onlyPredictionMarket {
        string memory upper = _toUpperCase(region);
        bytes32 regionHash = keccak256(bytes(upper));
        validRegions[regionHash] = true;
        invalidRegions[regionHash] = false;
        emit RegionAdded(upper);
    }

    function removeRegion(string calldata region) external onlyPredictionMarket {
        string memory upper = _toUpperCase(region);
        bytes32 regionHash = keccak256(bytes(upper));
        validRegions[regionHash] = false;
        invalidRegions[regionHash] = true;
        emit RegionRemoved(upper);
    }

    function isValidName(string memory name, uint8 gender, bytes32[] calldata proof) external view returns (bool) {
        bytes32 root = namesMerkleRoot[gender];
        if (!_isAsciiLowercaseLetters(name)) return false;
        if (root == bytes32(0)) return true;

        bytes32 nameHash = _nameKey(name, gender);
        if (approvedNames[nameHash]) return true;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(name, gender))));
        return MerkleProofLib.verify(proof, root, leaf);
    }

    function isValidRegion(string memory region) external view returns (bool) {
        if (bytes(region).length == 0) return true;
        string memory upper = _toUpperCase(region);
        bytes memory upperBytes = bytes(upper);
        bytes32 regionHash = keccak256(upperBytes);
        if (invalidRegions[regionHash]) return false;
        if (validRegions[regionHash]) return true;
        return defaultRegionsSeeded && _isDefaultStateRegion(upperBytes);
    }

    function _nameKey(string memory loweredName, uint8 gender) internal pure returns (bytes32) {
        return keccak256(abi.encode(loweredName, gender));
    }

    function _isAsciiLowercaseLetters(string memory str) internal pure returns (bool) {
        bytes memory b = bytes(str);
        if (b.length == 0) return false;
        for (uint256 i; i < b.length; i++) {
            if (b[i] < 0x61 || b[i] > 0x7A) return false;
        }
        return true;
    }

    function _toUpperCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bUpper = new bytes(bStr.length);
        for (uint256 i; i < bStr.length; i++) {
            if (bStr[i] >= 0x61 && bStr[i] <= 0x7A) {
                bUpper[i] = bytes1(uint8(bStr[i]) - 32);
            } else {
                bUpper[i] = bStr[i];
            }
        }
        return string(bUpper);
    }

    function _isDefaultStateRegion(bytes memory upperBytes) internal pure returns (bool) {
        if (upperBytes.length != 2) return false;

        uint8 a = uint8(upperBytes[0]);
        uint8 b = uint8(upperBytes[1]);
        if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return false;

        uint256 mask;
        unchecked {
            if (a == 0x41) mask = (1 << 11) | (1 << 10) | (1 << 25) | (1 << 17);
            else if (a == 0x43) mask = (1 << 0) | (1 << 14) | (1 << 19);
            else if (a == 0x44) mask = 1 << 4;
            else if (a == 0x46) mask = 1 << 11;
            else if (a == 0x47) mask = 1 << 0;
            else if (a == 0x48) mask = 1 << 8;
            else if (a == 0x49) mask = (1 << 3) | (1 << 11) | (1 << 13) | (1 << 0);
            else if (a == 0x4B) mask = (1 << 18) | (1 << 24);
            else if (a == 0x4C) mask = 1 << 0;
            else if (a == 0x4D) mask = (1 << 4) | (1 << 3) | (1 << 0) | (1 << 8) | (1 << 13) | (1 << 18) | (1 << 14) | (1 << 19);
            else if (a == 0x4E) mask = (1 << 4) | (1 << 21) | (1 << 7) | (1 << 9) | (1 << 12) | (1 << 24) | (1 << 2) | (1 << 3);
            else if (a == 0x4F) mask = (1 << 7) | (1 << 10);
            else if (a == 0x50) return b == 0x41;
            else if (a == 0x52) mask = 1 << 8;
            else if (a == 0x53) mask = (1 << 2) | (1 << 3);
            else if (a == 0x54) mask = (1 << 13) | (1 << 23);
            else if (a == 0x55) mask = 1 << 19;
            else if (a == 0x56) mask = (1 << 19) | (1 << 0);
            else if (a == 0x57) mask = (1 << 0) | (1 << 21) | (1 << 8) | (1 << 24);
            else return false;

            return (mask & (1 << (b - 0x41))) != 0;
        }
    }
}
