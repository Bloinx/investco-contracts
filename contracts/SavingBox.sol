// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SavingBox is ReentrancyGuard, Ownable {
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable POOL;
    IERC20 public immutable USDC;

    // Fuji testnet addresses
    address public constant POOL_ADDRESSES_PROVIDER = 0xfb87056c0587923f15EB0aABc7d0572450Cc8003;
    address public constant USDC_ADDRESS = 0xCaC7Ffa82c0f43EBB0FC11FCd32123EcA46626cf;

    enum Stages {
        Save,
        Finished
    }
    Stages public stage;

    struct User {
        address userAddr;
        uint256 availableSavings;
        uint8 validPayments;
        uint8 latePayments;
        bool isActive;
    }

    mapping(address => User) public users;
    address[] public addressOrderList;

    // State variables
    uint256 public immutable saveAmount;
    uint256 public immutable numPayments;
    uint256 public immutable totalTargetSavings;
    uint256 public immutable paymentInterval;
    uint256 public immutable startTime;
    uint256 public immutable withdrawFee;
    
    uint8 public currentPaymentNumber = 1;
    uint256 public totalSavings;

    // Events
    event BoxCreated(uint256 indexed saveAmount, uint256 indexed numPayments, uint256 paymentInterval);
    event UserRegistered(address indexed user);
    event PaymentMade(address indexed user, uint256 amount, uint8 paymentNumber);
    event FundsWithdrawn(address indexed user, uint256 amount, uint256 fee);
    event StageChanged(Stages newStage);

    // Custom errors
    error InvalidAmount();
    error InvalidPaymentInterval();
    error InvalidNumPayments();
    error PaymentsUpToDate();
    error NoMorePayments();
    error UserNotRegistered();
    error TransferFailed();
    error WithdrawalTooLarge();

    constructor(
        uint256 _saveAmount,
        uint256 _numPayments,
        uint256 _paymentInterval,
        uint256 _withdrawFee
    ) Ownable(msg.sender) {
        if (_saveAmount == 0) revert InvalidAmount();
        if (_paymentInterval == 0) revert InvalidPaymentInterval();
        if (_numPayments == 0) revert InvalidNumPayments();

        saveAmount = _saveAmount * 10**6;
        numPayments = _numPayments;
        paymentInterval = _paymentInterval * 60;
        withdrawFee = _withdrawFee;
        totalTargetSavings = saveAmount * numPayments;
        startTime = block.timestamp;
        
        ADDRESSES_PROVIDER = IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER);
        POOL = IPool(ADDRESSES_PROVIDER.getPool());
        USDC = IERC20(USDC_ADDRESS);
        
        stage = Stages.Save;
        emit BoxCreated(saveAmount, numPayments, paymentInterval);
    }

    modifier atStage(Stages _stage) {
        require(stage == _stage, "Invalid stage");
        _;
    }

    modifier onlyActiveUser() {
        if (!users[msg.sender].isActive) revert UserNotRegistered();
        _;
    }

    function addPayment() 
        external 
        nonReentrant 
        atStage(Stages.Save) 
    {
        uint8 realPayment = getCurrentPaymentNumber();
        if (realPayment > numPayments) revert NoMorePayments();
        
        uint256 userFuturePayments = getFuturePayments(msg.sender);
        if (saveAmount > userFuturePayments) revert PaymentsUpToDate();

        if (currentPaymentNumber < realPayment) {
            _advancePayment();
        }

        if (currentPaymentNumber == 1 && !users[msg.sender].isActive) {
            _registerUser(msg.sender);
        }

        _processPayment(msg.sender);
    }

    function withdraw(uint256 amount) 
        external 
        nonReentrant 
        onlyActiveUser 
    {
        if (amount > users[msg.sender].availableSavings) revert WithdrawalTooLarge();
        
        uint256 fee = (amount * withdrawFee) / 100;
        uint256 netAmount = amount - fee;

        // Update state before external calls
        users[msg.sender].availableSavings -= amount;
        totalSavings -= amount;

        // Withdraw from Aave
        POOL.withdraw(
            USDC_ADDRESS,
            netAmount,
            msg.sender
        );

        if (fee > 0) {
            POOL.withdraw(
                USDC_ADDRESS,
                fee,
                owner()
            );
        }

        emit FundsWithdrawn(msg.sender, netAmount, fee);
    }

    // Internal functions
    function _registerUser(address user) private {
        users[user] = User(user, 0, 0, 0, true);
        addressOrderList.push(user);
        emit UserRegistered(user);
    }

    function _processPayment(address user) private {
        USDC.transferFrom(user, address(this), saveAmount);
        USDC.approve(address(POOL), saveAmount);

        POOL.supply(
            USDC_ADDRESS,
            saveAmount,
            address(this),
            0
        );

        users[user].availableSavings += saveAmount;
        users[user].validPayments++;
        totalSavings += saveAmount;

        emit PaymentMade(user, saveAmount, currentPaymentNumber);
    }

    function _advancePayment() private {
        for (uint256 i = 0; i < addressOrderList.length; i++) {
            address userAddress = addressOrderList[i];
            uint256 donePayments = users[userAddress].availableSavings / saveAmount;
            
            if (donePayments < currentPaymentNumber) {
                if (currentPaymentNumber - users[userAddress].latePayments > donePayments) {
                    users[userAddress].latePayments++;
                }
            }
        }
        currentPaymentNumber++;
    }

    // View functions
    function getFuturePayments(address user) public view returns (uint256) {
        return totalTargetSavings - users[user].availableSavings;
    }

    function getCurrentPaymentNumber() public view returns (uint8) {
        return uint8((block.timestamp - startTime) / paymentInterval) + 1;
    }

    function getUserCount() public view returns (uint256) {
        return addressOrderList.length;
    }

    function getUSDCBalance(address user) external view returns (uint256) {
        return USDC.balanceOf(user);
    }

    function getBoxAaveBalance() external view returns (uint256) {
        (uint256 totalCollateralBase, , , , , ) = POOL.getUserAccountData(address(this));
        return totalCollateralBase;
    }
}