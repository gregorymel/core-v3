// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {PriceUpdate} from "../interfaces/base/IPriceFeedStore.sol";
import {PERCENTAGE_FACTOR} from "../libraries/Constants.sol";
import {BalanceDelta, BalancesLogic, Comparison, Balance} from "../libraries/BalancesLogic.sol";
import {FullCheckParams} from "../interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "../interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditFacadeV3Hooks} from "../interfaces/ICreditFacadeV3Hooks.sol";
import {ManageDebtAction} from "../interfaces/ICreditManagerV3.sol";
import {CreditFacadeV32} from "./CreditFacadeV32.sol";
import {
    CallerNotCreditAccountOwnerException,
    BalanceLessThanExpectedException,
    ExpectedBalancesAlreadySetException,
    ExpectedBalancesNotSetException,
    ForbiddenTokensException,
    NotImplementedException
} from "../interfaces/IExceptions.sol";

struct MulticallContext {
    address creditAccount;
    uint256 enabledTokensMask;
    bytes fullCheckParamsPacked;
    bytes expectedBalancesPacked;
}

contract CreditFacadeV3_Multicall is CreditFacadeV32, ICreditFacadeV3Multicall, ICreditFacadeV3Hooks {
    bytes32 internal constant MULTICALL_CONTEXT_STORAGE_SLOT = keccak256("credit.facade.v3.multicall.context");

    /// @dev Ensures that function caller is `creditAccount` itself
    modifier creditAccountOnly() {
        _checkCreditAccountOwner(msg.sender);
        _;
    }

    modifier whenExecuting() {
        address creditAccount = _getMulticallContext().creditAccount;
        if (creditAccount != msg.sender) revert CallerNotCreditAccountOwnerException();
        _;
    }

    constructor(
        address _addressProvider,
        address _creditManager,
        address _lossPolicy,
        address _botList,
        address _weth,
        address _degenNFT,
        bool _expirable
    ) CreditFacadeV32(_addressProvider, _creditManager, _lossPolicy, _botList, _weth, _degenNFT, _expirable) {}

    function onBeforeExecution() external override creditAccountOnly {
        _checkBeforeExecution(msg.sender);
    }

    function onAfterExecution() external override whenExecuting {
        _checkAfterExecution(msg.sender);
    }

    function onDemandPriceUpdates(PriceUpdate[] calldata /*updates*/ ) external override whenExecuting {
        _onDemandPriceUpdates(msg.data[4:]);
    }

    function storeExpectedBalances(BalanceDelta[] calldata balanceDeltas) external override whenExecuting {
        MulticallContext storage $context = _getMulticallContext();
        address creditAccount = $context.creditAccount;

        if ($context.expectedBalancesPacked.length != 0) revert ExpectedBalancesAlreadySetException();
        $context.expectedBalancesPacked = abi.encode(BalancesLogic.storeBalances(creditAccount, balanceDeltas));
    }

    function compareBalances() external override whenExecuting {
        address creditAccount = msg.sender;
        MulticallContext storage $context = _getMulticallContext();

        if ($context.expectedBalancesPacked.length == 0) revert ExpectedBalancesNotSetException();
        Balance[] memory expectedBalances = abi.decode($context.expectedBalancesPacked, (Balance[]));
        address failedToken =
            BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER_OR_EQUAL);
        if (failedToken != address(0)) revert BalanceLessThanExpectedException(failedToken);
        $context.expectedBalancesPacked = "";
    }

    function updateQuota(address, /*token*/ int96, /*quotaChange*/ uint96 /*minQuota*/ )
        external
        override
        whenExecuting
    {
        MulticallContext storage $context = _getMulticallContext();

        // _revertIfNoPermission($context.flags, UPDATE_QUOTA_PERMISSION);
        ($context.enabledTokensMask,) =
            _updateQuota($context.creditAccount, msg.data[4:], $context.enabledTokensMask, type(uint256).max);
    }

    function increaseDebt(uint256 amount) external override whenExecuting {
        MulticallContext storage $context = _getMulticallContext();
        _manageDebt(msg.sender, amount, $context.enabledTokensMask, ManageDebtAction.INCREASE_DEBT); // U:[FA-27]
    }

    function decreaseDebt(uint256 amount) external override whenExecuting {
        MulticallContext storage $context = _getMulticallContext();
        _manageDebt(msg.sender, amount, $context.enabledTokensMask, ManageDebtAction.DECREASE_DEBT); // U:[FA-31]
    }

    function addCollateral(address token, uint256 amount) external override {
        revert NotImplementedException();
    }

    function addCollateralWithPermit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        revert NotImplementedException();
    }

    function withdrawCollateral(address token, uint256 amount, address to) external override {
        revert NotImplementedException();
    }

    function setBotPermissions(address bot, uint192 permissions) external override {
        revert NotImplementedException();
    }

    function setFullCheckParams(uint256[] calldata collateralHints, uint16 minHealthFactor)
        external
        override
        whenExecuting
    {
        MulticallContext storage $context = _getMulticallContext();

        FullCheckParams memory fullCheckParams;
        _setFullCheckParams(fullCheckParams, msg.data[4:]);

        $context.fullCheckParamsPacked = abi.encode(fullCheckParams);
    }

    function _getMulticallContext() internal pure returns (MulticallContext storage $context) {
        bytes32 slot = MULTICALL_CONTEXT_STORAGE_SLOT;
        assembly {
            $context.slot := slot
        }
    }

    function _checkBeforeExecution(address creditAccount) internal {
        MulticallContext storage $context = _getMulticallContext();

        $context.creditAccount = creditAccount;
        $context.enabledTokensMask = _enabledTokensMaskOf(creditAccount);
        $context.fullCheckParamsPacked = "";
        $context.expectedBalancesPacked = "";

        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender});
    }

    function _checkAfterExecution(address creditAccount) internal {
        MulticallContext storage $context = _getMulticallContext();

        uint256 forbiddenTokensMask = _forbiddenTokensMaskRoE(type(uint256).max);

        if ($context.expectedBalancesPacked.length != 0) {
            Balance[] memory expectedBalances = abi.decode($context.expectedBalancesPacked, (Balance[]));
            address failedToken =
                BalancesLogic.compareBalances(creditAccount, expectedBalances, Comparison.GREATER_OR_EQUAL);
            if (failedToken != address(0)) revert BalanceLessThanExpectedException(failedToken); // U:[FA-23]
        }

        emit FinishMultiCall(); // U:[FA-18]

        uint256 enabledForbiddenTokensMask = $context.enabledTokensMask & forbiddenTokensMask;
        if (enabledForbiddenTokensMask != 0) {
            revert ForbiddenTokensException(enabledForbiddenTokensMask);
        }

        FullCheckParams memory fullCheckParams;
        if ($context.fullCheckParamsPacked.length != 0) {
            fullCheckParams = abi.decode($context.fullCheckParamsPacked, (FullCheckParams));
        } else {
            fullCheckParams.minHealthFactor = PERCENTAGE_FACTOR;
            fullCheckParams.collateralHints = new uint256[](0);
        }

        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMask: $context.enabledTokensMask,
            collateralHints: fullCheckParams.collateralHints,
            minHealthFactor: fullCheckParams.minHealthFactor,
            useSafePrices: true // $context.flags & USE_SAFE_PRICES_FLAG != 0
        });

        $context.creditAccount = address(0);
    }
}
