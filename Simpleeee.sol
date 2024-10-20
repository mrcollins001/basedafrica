// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface ICrossChainMessenger {
    function sendMessage(uint256 destinationChainId, address recipient, bytes memory message) external;
    function receiveMessage(uint256 sourceChainId, address sender, bytes memory message) external;
}

contract BridgeContract is ReentrancyGuard {
    using ECDSA for bytes32;

    address public owner;
    IERC20 public token;
    ICrossChainMessenger public crossChainMessenger;
    uint256 public constant MIN_TRANSFER_AMOUNT = 1e18; // 1 token
    uint256 public constant MAX_TRANSFER_AMOUNT = 1000e18; // 1000 tokens

    mapping(bytes32 => bool) public processedTransfers;
    mapping(address => bool) public authorizedValidators;

    event TokensLocked(address indexed from, uint256 amount, bytes32 transferId, uint256 destinationChainId);
    event TokensUnlocked(address indexed to, uint256 amount, bytes32 transferId, uint256 sourceChainId);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event CrossChainMessageSent(uint256 destinationChainId, bytes32 transferId);
    event CrossChainMessageReceived(uint256 sourceChainId, bytes32 transferId);

    constructor(address _token, address _crossChainMessenger) {
        owner = msg.sender;
        token = IERC20(_token);
        crossChainMessenger = ICrossChainMessenger(_crossChainMessenger);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    function lockTokens(uint256 amount, bytes32 transferId, uint256 destinationChainId) external nonReentrant {
        require(amount >= MIN_TRANSFER_AMOUNT && amount <= MAX_TRANSFER_AMOUNT, "Invalid transfer amount");
        require(!processedTransfers[transferId], "Transfer already processed");

        processedTransfers[transferId] = true;
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        emit TokensLocked(msg.sender, amount, transferId, destinationChainId);

        // Send cross-chain message
        bytes memory message = abi.encode(msg.sender, amount, transferId);
        crossChainMessenger.sendMessage(destinationChainId, address(this), message);
        emit CrossChainMessageSent(destinationChainId, transferId);
    }

    function unlockTokens(
        address to,
        uint256 amount,
        bytes32 transferId,
        uint256 sourceChainId,
        bytes[] memory signatures
    ) external nonReentrant {
        require(!processedTransfers[transferId], "Transfer already processed");
        require(verifySignatures(to, amount, transferId, sourceChainId, signatures), "Invalid signatures");

        processedTransfers[transferId] = true;
        require(token.transfer(to, amount), "Token transfer failed");

        emit TokensUnlocked(to, amount, transferId, sourceChainId);
    }

    function verifySignatures(
        address to,
        uint256 amount,
        bytes32 transferId,
        uint256 sourceChainId,
        bytes[] memory signatures
    ) internal view returns (bool) {
        bytes32 message = keccak256(abi.encodePacked(to, amount, transferId, sourceChainId, block.chainid));
        bytes32 ethSignedMessage = message.toEthSignedMessageHash();

        uint256 validSignatures = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ethSignedMessage.recover(signatures[i]);
            if (authorizedValidators[signer]) {
                validSignatures++;
            }
        }

        // Require at least 2/3 of validators to sign
        return validSignatures * 3 > authorizedValidators.length * 2;
    }

    function receiveMessage(uint256 sourceChainId, address sender, bytes memory message) external {
        require(msg.sender == address(crossChainMessenger), "Only cross-chain messenger can call this function");
        
        (address from, uint256 amount, bytes32 transferId) = abi.decode(message, (address, uint256, bytes32));
        require(!processedTransfers[transferId], "Transfer already processed");

        processedTransfers[transferId] = true;
        emit CrossChainMessageReceived(sourceChainId, transferId);

        // Implement logic to mint or release tokens on this chain
        // This could involve minting new tokens or releasing from a locked pool
        // For simplicity, we'll just transfer tokens here
        require(token.transfer(from, amount), "Token transfer failed");

        emit TokensUnlocked(from, amount, transferId, sourceChainId);
    }

    function addValidator(address validator) external onlyOwner {
        require(!authorizedValidators[validator], "Validator already exists");
        authorizedValidators[validator] = true;
        emit ValidatorAdded(validator);
    }

    function removeValidator(address validator) external onlyOwner {
        require(authorizedValidators[validator], "Validator does not exist");
        authorizedValidators[validator] = false;
        emit ValidatorRemoved(validator);
    }

    function setToken(address _token) external onlyOwner {
        token = IERC20(_token);
    }

    function setCrossChainMessenger(address _crossChainMessenger) external onlyOwner {
        crossChainMessenger = ICrossChainMessenger(_crossChainMessenger);
    }

    function withdrawTokens(address to, uint256 amount) external onlyOwner {
        require(token.transfer(to, amount), "Token transfer failed");
    }
}

// UI/UX Design for Bridge (React Component)
/*
import React, { useState, useEffect } from 'react';
import Web3 from 'web3';
import BridgeContract from './BridgeContract.json';

const BridgeUI = () => {
    const [web3, setWeb3] = useState(null);
    const [account, setAccount] = useState('');
    const [contract, setContract] = useState(null);
    const [amount, setAmount] = useState('');
    const [destinationChain, setDestinationChain] = useState('');
    const [loading, setLoading] = useState(false);
    const [error, setError] = useState('');
    const [success, setSuccess] = useState('');

    useEffect(() => {
        const initWeb3 = async () => {
            if (window.ethereum) {
                const web3Instance = new Web3(window.ethereum);
                try {
                    await window.ethereum.enable();
                    setWeb3(web3Instance);
                    const accounts = await web3Instance.eth.getAccounts();
                    setAccount(accounts[0]);
                    const networkId = await web3Instance.eth.net.getId();
                    const deployedNetwork = BridgeContract.networks[networkId];
                    const instance = new web3Instance.eth.Contract(
                        BridgeContract.abi,
                        deployedNetwork && deployedNetwork.address,
                    );
                    setContract(instance);
                } catch (error) {
                    console.error("User denied account access");
                }
            }
        };
        initWeb3();
    }, []);

    const handleTransfer = async (e) => {
        e.preventDefault();
        setLoading(true);
        setError('');
        setSuccess('');
        try {
            const transferId = web3.utils.randomHex(32);
            await contract.methods.lockTokens(
                web3.utils.toWei(amount, 'ether'),
                transferId,
                destinationChain
            ).send({ from: account });
            setSuccess('Transfer initiated successfully!');
        } catch (err) {
            setError('Transfer failed. Please try again.');
            console.error(err);
        }
        setLoading(false);
    };

    return (
        <div className="bridge-ui">
            <h1>Token Bridge</h1>
            <form onSubmit={handleTransfer}>
                <div>
                    <label>Amount:</label>
                    <input 
                        type="text" 
                        value={amount} 
                        onChange={(e) => setAmount(e.target.value)}
                        placeholder="Enter amount"
                    />
                </div>
                <div>
                    <label>Destination Chain:</label>
                    <select 
                        value={destinationChain} 
                        onChange={(e) => setDestinationChain(e.target.value)}
                    >
                        <option value="">Select chain</option>
                        <option value="1">Ethereum</option>
                        <option value="56">Binance Smart Chain</option>
                    </select>
                </div>
                <button type="submit" disabled={loading}>
                    {loading ? 'Processing...' : 'Transfer'}
                </button>
            </form>
            {error && <p className="error">{error}</p>}
            {success && <p className="success">{success}</p>}
        </div>
    );
};

export default BridgeUI;
*/

// CSS for Bridge UI
/*
.bridge-ui {
    max-width: 500px;
    margin: 0 auto;
    padding: 20px;
    font-family: Arial, sans-serif;
}

h1 {
    text-align: center;
    color: #333;
}

form {
    display: flex;
    flex-direction: column;
    gap: 15px;
}

label {
    font-weight: bold;
}

input, select {
    width: 100%;
    padding: 10px;
    border: 1px solid #ddd;
    border-radius: 4px;
}

button {
    background-color: #4CAF50;
    color: white;
    padding: 10px 15px;
    border: none;
    border-radius: 4px;
    cursor: pointer;
    font-size: 16px;
}

button:disabled {
    background-color: #ddd;
    cursor: not-allowed;
}

.error {
    color: red;
}

.success {
    color: green;
}
*/



