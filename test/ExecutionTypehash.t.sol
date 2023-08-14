// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';
import {SignatureChecker} from 'openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol';
import {IParam} from 'src/interfaces/IParam.sol';
import {TypedDataSignature} from './utils/TypedDataSignature.sol';

contract ExecutionTypehash is Test, TypedDataSignature {
    using SignatureChecker for address;

    uint256 public constant PRIVATE_KEY = 0x290441b34d375a426eb23e32d27296fe944c734f58b21a1d2736191dfaafce90;
    address public constant SIGNER = 0x8C9dB529b394C8E1a9Fa34AE90F228202ca40712;

    uint256 public chainId;
    address public verifyingContract;

    function setUp() public {
        verifyingContract = 0x712BcCD6b7f8f5c3faE0418AC917f8929b371804;
        chainId = 1;
    }

    function _buildDomainSeparator() internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
        );
        bytes32 nameHash = keccak256('Protocolink');
        bytes32 versionHash = keccak256('1');
        return keccak256(abi.encode(typeHash, nameHash, versionHash, chainId, verifyingContract));
    }

    function testExecutionTypehash() external {
        // Sign an execution using metamask to obtain an external sig
        // https://github.com/dinngo/test-dapp/tree/for-protocolink-contract
        bytes32 r = 0x8e65bac0b03b4929e6fa2bd08d0ff2aa54830b7b0f6952a37746186e0247b1c0;
        bytes32 s = 0x53fcfdf3e742855dbce317e007bebd221a2a81e496f5a099dfd2f5eaddd02962;
        uint8 v = 0x1c;
        bytes memory sig = bytes.concat(r, s, bytes1(v));

        // Create the execution with the same parameters as above
        IParam.Input[] memory inputs = new IParam.Input[](2);
        inputs[0] = IParam.Input(
            address(1), // token
            type(uint256).max, // balanceBps
            1 // amountOrOffset
        );
        inputs[1] = IParam.Input(
            address(2), // token
            10000, // balanceBps
            0x20 // amountOrOffset
        );
        IParam.Logic[] memory logics = new IParam.Logic[](2);
        logics[0] = IParam.Logic(
            address(3), // to
            '0123456789abcdef',
            inputs,
            IParam.WrapMode.WRAP_BEFORE,
            address(4), // approveTo
            address(5) // callback
        );
        logics[1] = logics[0]; // Duplicate logic
        address[] memory tokensReturn = new address[](2);
        tokensReturn[0] = address(6);
        tokensReturn[1] = address(7);
        uint256 referralCode = 8;
        uint256 nonce = 9;
        uint256 deadline = 1704067200;
        IParam.ExecutionDetails memory details = IParam.ExecutionDetails(
            logics,
            tokensReturn,
            referralCode,
            nonce,
            deadline
        );

        // Verify the locally generated signature using the private key is the same as the external sig
        assertEq(getTypedDataSignature(details, _buildDomainSeparator(), PRIVATE_KEY), sig);

        // Verify the signer can be recovered using the external sig
        bytes32 hashedTypedData = getHashedTypedData(details, _buildDomainSeparator());
        assertEq(SIGNER.isValidSignatureNow(hashedTypedData, sig), true);
    }

    function testExecutionBatchTypehash() external {
        // Sign an execution using metamask to obtain an external sig
        // https://github.com/dinngo/test-dapp/tree/for-protocolink-contract
        bytes32 r = 0x3b69de043a6e284b833aa7aae1a5a1ef21d8575da87ab8e6197336ffd2b5adb3;
        bytes32 s = 0x3bd9781323656e313a6122b57423eee4c11a862c63b5ad4173d43db5ecb274d6;
        uint8 v = 0x1c;
        bytes memory sig = bytes.concat(r, s, bytes1(v));

        // Create the execution with the same parameters as above
        IParam.Input[] memory inputs = new IParam.Input[](2);
        inputs[0] = IParam.Input(
            address(1), // token
            type(uint256).max, // balanceBps
            1 // amountOrOffset
        );
        inputs[1] = IParam.Input(
            address(2), // token
            10000, // balanceBps
            0x20 // amountOrOffset
        );
        IParam.Logic[] memory logics = new IParam.Logic[](2);
        logics[0] = IParam.Logic(
            address(3), // to
            '0123456789abcdef',
            inputs,
            IParam.WrapMode.WRAP_BEFORE,
            address(4), // approveTo
            address(5) // callback
        );
        logics[1] = logics[0]; // Duplicate logic
        IParam.Fee[] memory fees = new IParam.Fee[](2);
        fees[0] = IParam.Fee(address(6), 1, bytes32(abi.encodePacked('metadata')));
        fees[1] = fees[0]; // Duplicate fee
        uint256 deadline = 1704067200;
        IParam.LogicBatch memory logicBatch = IParam.LogicBatch(logics, fees, deadline);
        address[] memory tokensReturn = new address[](2);
        tokensReturn[0] = address(6);
        tokensReturn[1] = address(7);
        uint256 referralCode = 8;
        uint256 nonce = 9;
        IParam.ExecutionBatchDetails memory details = IParam.ExecutionBatchDetails(
            logicBatch,
            tokensReturn,
            referralCode,
            nonce,
            deadline
        );

        // Verify the locally generated signature using the private key is the same as the external sig
        assertEq(getTypedDataSignature(details, _buildDomainSeparator(), PRIVATE_KEY), sig);

        // Verify the signer can be recovered using the external sig
        bytes32 hashedTypedData = getHashedTypedData(details, _buildDomainSeparator());
        assertTrue(SIGNER.isValidSignatureNow(hashedTypedData, sig));
    }
}
