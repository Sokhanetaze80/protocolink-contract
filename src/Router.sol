// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {EIP712} from 'openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol';
import {SignatureChecker} from 'openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol';
import {IAgent, AgentImplementation} from './AgentImplementation.sol';
import {Agent} from './Agent.sol';
import {IParam} from './interfaces/IParam.sol';
import {IRouter} from './interfaces/IRouter.sol';
import {LogicHash} from './libraries/LogicHash.sol';
import {IFeeCalculator} from './interfaces/IFeeCalculator.sol';

/// @title Router executes arbitrary logics
contract Router is IRouter, EIP712, Ownable {
    using LogicHash for IParam.LogicBatch;
    using SignatureChecker for address;

    address private constant _INIT_USER = address(1);
    address private constant _INVALID_PAUSER = address(0);
    address private constant _INVALID_FEE_COLLECTOR = address(0);
    address private constant _NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes4 private constant _NATIVE_FEE_SELECTOR = 0xeeeeeeee;
    address private constant _DUMMY_ERC20_TOKEN = address(0xe20);
    bytes4 private constant _ERC20_TRANSFER_FROM_SELECTOR =
        bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));

    address public immutable agentImplementation;

    mapping(address owner => IAgent agent) public agents;
    mapping(address signer => bool valid) public signers;
    mapping(bytes4 selector => mapping(address to => address feeCalculator)) public feeCalculators;
    address public user;
    address public feeCollector;
    address public pauser;
    bool public paused;

    modifier checkCaller() {
        if (user == _INIT_USER) {
            user = msg.sender;
        } else {
            revert Reentrancy();
        }
        _;
        user = _INIT_USER;
    }

    modifier isPaused() {
        if (paused) revert RouterIsPaused();
        _;
    }

    modifier onlyPauser() {
        if (msg.sender != pauser) revert InvalidPauser();
        _;
    }

    constructor(address wrappedNative, address pauser_, address feeCollector_) EIP712('Composable Router', '1') {
        user = _INIT_USER;
        agentImplementation = address(new AgentImplementation(wrappedNative));
        _setPauser(pauser_);
        _setFeeCollector(feeCollector_);
    }

    function owner() public view override(IRouter, Ownable) returns (address) {
        return super.owner();
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getAgent() external view returns (address) {
        return address(agents[user]);
    }

    function getAgent(address owner_) external view returns (address) {
        return address(agents[owner_]);
    }

    function getUserAgent() external view returns (address, address) {
        address _user = user;
        return (_user, address(agents[_user]));
    }

    function calcAgent(address owner_) external view returns (address) {
        address result = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            bytes32(bytes20((uint160(owner_)))),
                            keccak256(abi.encodePacked(type(Agent).creationCode, abi.encode(agentImplementation)))
                        )
                    )
                )
            )
        );
        return result;
    }

    /// @notice Get logics, fees and msg.value that contains fee
    function getLogicsAndFees(
        IParam.Logic[] memory logics,
        uint256 msgValue
    ) external view returns (IParam.Logic[] memory, IParam.Fee[] memory, uint256) {
        // Update logics
        logics = getLogicsDataWithFee(logics);

        // Update value
        if (msgValue > 0) {
            address nativeFeeCalculator = feeCalculators[_NATIVE_FEE_SELECTOR][_NATIVE];
            if (nativeFeeCalculator != address(0)) {
                msgValue = uint256(
                    bytes32(IFeeCalculator(nativeFeeCalculator).getDataWithFee(abi.encodePacked(msgValue)))
                );
            }
        }

        // Get fees
        IParam.Fee[] memory fees = getFeesByLogics(logics, msgValue);

        return (logics, fees, msgValue);
    }

    function getLogicsDataWithFee(IParam.Logic[] memory logics) public view returns (IParam.Logic[] memory) {
        uint256 length = logics.length;
        for (uint256 i = 0; i < length; ) {
            bytes memory data = logics[i].data;
            address to = logics[i].to;
            bytes4 selector = bytes4(data);
            if (selector == _ERC20_TRANSFER_FROM_SELECTOR) to = _DUMMY_ERC20_TOKEN; // ERC20 transferFrom case
            address feeCalculator = feeCalculators[selector][to];
            if (feeCalculator != address(0)) {
                // Get transaction data with fee
                logics[i].data = IFeeCalculator(feeCalculator).getDataWithFee(data);
            }
            unchecked {
                ++i;
            }
        }

        return logics;
    }

    function addSigner(address signer) external onlyOwner {
        signers[signer] = true;
        emit SignerAdded(signer);
    }

    function removeSigner(address signer) external onlyOwner {
        delete signers[signer];
        emit SignerRemoved(signer);
    }

    /// @notice Set fee calculator contracts
    function setFeeCalculators(
        bytes4[] calldata selectors,
        address[] calldata tos,
        address[] calldata feeCalculators_
    ) external onlyOwner {
        uint256 length = selectors.length;
        if (length != tos.length) revert LengthMismatch();
        if (length != feeCalculators_.length) revert LengthMismatch();

        for (uint256 i = 0; i < length; ) {
            bytes4 selector = selectors[i];
            address to = tos[i];
            address feeCalculator = feeCalculators_[i];
            feeCalculators[selector][to] = feeCalculator;
            emit FeeCalculatorSet(selector, to, feeCalculator);
            unchecked {
                ++i;
            }
        }
    }

    function setFeeCollector(address feeCollector_) external onlyOwner {
        _setFeeCollector(feeCollector_);
    }

    function _setFeeCollector(address feeCollector_) internal {
        if (feeCollector_ == _INVALID_FEE_COLLECTOR) revert InvalidFeeCollector();
        feeCollector = feeCollector_;
        emit FeeCollectorSet(feeCollector_);
    }

    function setPauser(address pauser_) external onlyOwner {
        _setPauser(pauser_);
    }

    function _setPauser(address pauser_) internal {
        if (pauser_ == _INVALID_PAUSER) revert InvalidNewPauser();
        pauser = pauser_;
        emit PauserSet(pauser_);
    }

    function pause() external onlyPauser {
        paused = true;
        emit Paused();
    }

    function resume() external onlyPauser {
        paused = false;
        emit Resumed();
    }

    /// @notice Execute logics through user's agent. Create agent for user if not created.
    function execute(
        IParam.Logic[] calldata logics,
        IParam.Fee[] calldata fees,
        address[] calldata tokensReturn,
        uint256 referral
    ) external payable isPaused checkCaller {
        _verifyFees(logics, fees, msg.value);

        IAgent agent = agents[user];

        if (address(agent) == address(0)) {
            agent = IAgent(newAgent(user));
        }

        emit Execute(user, address(agent), referral);
        agent.execute{value: msg.value}(logics, fees, tokensReturn);
    }

    /// @notice Execute logics with signer's signature.
    function executeWithSignature(
        IParam.LogicBatch calldata logicBatch,
        address signer,
        bytes calldata signature,
        address[] calldata tokensReturn,
        uint256 referral
    ) external payable isPaused checkCaller {
        // Verify deadline, signer and signature
        uint256 deadline = logicBatch.deadline;
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (!signers[signer]) revert InvalidSigner(signer);
        if (!signer.isValidSignatureNow(_hashTypedDataV4(logicBatch._hash()), signature)) revert InvalidSignature();

        IAgent agent = agents[user];

        if (address(agent) == address(0)) {
            agent = IAgent(newAgent(user));
        }

        emit Execute(user, address(agent), referral);
        agent.execute{value: msg.value}(logicBatch.logics, logicBatch.fees, tokensReturn);
    }

    /// @notice Create an agent for `msg.sender`
    function newAgent() external returns (address payable) {
        return newAgent(msg.sender);
    }

    /// @notice Create an agent for `owner_`
    function newAgent(address owner_) public returns (address payable) {
        if (address(agents[owner_]) != address(0)) {
            revert AgentAlreadyCreated();
        } else {
            IAgent agent = IAgent(address(new Agent{salt: bytes32(bytes20((uint160(owner_))))}(agentImplementation)));
            agents[owner_] = agent;
            emit AgentCreated(address(agent), owner_);
            return payable(address(agent));
        }
    }

    function getFeesByLogics(IParam.Logic[] memory logics, uint256 msgValue) public view returns (IParam.Fee[] memory) {
        IParam.Fee[] memory tempFees = new IParam.Fee[](32); // Create a temporary `tempFees` with size 32 to store fee
        uint256 realFeeLength;
        uint256 logicsLength = logics.length;
        for (uint256 i = 0; i < logicsLength; ++i) {
            bytes memory data = logics[i].data;
            address to = logics[i].to;
            bytes4 selector = bytes4(data);

            // Get feeCalculator
            address feeCalculator = selector == _ERC20_TRANSFER_FROM_SELECTOR
                ? feeCalculators[selector][_DUMMY_ERC20_TOKEN] // ERC20 transferFrom case
                : feeCalculators[selector][to];
            if (feeCalculator == address(0)) {
                continue; // No need to charge fee
            }

            // Get charge tokens and amounts
            (address[] memory tokens, uint256[] memory amounts, bytes32 metadata) = IFeeCalculator(feeCalculator)
                .getFees(data);
            uint256 tokensLength = tokens.length;
            if (tokensLength == 0) {
                continue; // No need to charge fee
            }

            for (uint256 feeIndex = 0; feeIndex < tokensLength; ++feeIndex) {
                tempFees[realFeeLength] = IParam.Fee({
                    token: tokens[feeIndex] == _DUMMY_ERC20_TOKEN ? to : tokens[feeIndex],
                    amount: amounts[feeIndex],
                    metadata: metadata
                });

                realFeeLength++;
            }
        }

        if (msgValue > 0) {
            // For native fee
            address nativeFeeCalculator = feeCalculators[_NATIVE_FEE_SELECTOR][_NATIVE];
            if (nativeFeeCalculator != address(0)) {
                (address[] memory tokens, uint256[] memory amounts, bytes32 metadata) = IFeeCalculator(
                    nativeFeeCalculator
                ).getFees(abi.encodePacked(msgValue));

                tempFees[realFeeLength] = IParam.Fee({token: tokens[0], amount: amounts[0], metadata: metadata});
                realFeeLength++;
            }
        }

        // Copy tempFees to fees
        IParam.Fee[] memory fees = new IParam.Fee[](realFeeLength);
        for (uint256 i = 0; i < realFeeLength; ++i) {
            fees[i] = tempFees[i];
        }

        return fees;
    }

    function _verifyFees(IParam.Logic[] calldata logics, IParam.Fee[] memory fees, uint256 msgValue) private view {
        IParam.Fee[] memory expectedFees = getFeesByLogics(logics, msgValue);
        uint256 expectedFeesLength = expectedFees.length;
        if (expectedFeesLength == 0) return;

        uint256 feesLength = fees.length;
        for (uint256 i = 0; i < expectedFeesLength; ) {
            address expectedFeeToken = expectedFees[i].token;
            for (uint256 j = 0; j < feesLength; ) {
                if (expectedFeeToken == fees[j].token) {
                    expectedFees[i].amount -= fees[j].amount;
                }
                unchecked {
                    ++j;
                }
            }

            // Verify all fees amount are 0 to ensure the fees are valid
            if (expectedFees[i].amount > 0) revert FeeNotEnough(expectedFeeToken);

            unchecked {
                ++i;
            }
        }
    }
}
