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
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {Balance} from "../libraries/BalancesLogic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {CollateralDebtData} from "../interfaces/ICreditManagerV3.sol";
import {ILossPolicy} from "../interfaces/base/ILossPolicy.sol";
import {
    CallerNotCreditAccountOwnerException,
    BalanceLessThanExpectedException,
    ExpectedBalancesAlreadySetException,
    ExpectedBalancesNotSetException,
    ForbiddenTokensException,
    NotImplementedException,
    TokenNotAllowedException,
    CreditAccountNotLiquidatableWithLossException,
    InsufficientRemainingFundsException
} from "../interfaces/IExceptions.sol";
import {IPriceOracleV3} from "../interfaces/IPriceOracleV3.sol";
import {ICreditManagerV3} from "../interfaces/ICreditManagerV3.sol";
import {IPoolQuotaKeeperV3} from "../interfaces/IPoolQuotaKeeperV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/console.sol";

struct MulticallContext {
    address creditAccount;
    uint256 enabledTokensMask;
    bytes fullCheckParamsPacked;
    bytes expectedBalancesPacked;
}

struct LiquidationContext {
    address creditAccount;
    uint256 maxFeeAmount;
    uint256 minUnderlyingBalance;
    bool hasBadDebt;
    bytes collateralDebtDataPacked;
}

contract CreditFacadeV3_Multicall is CreditFacadeV32, ICreditFacadeV3Multicall, ICreditFacadeV3Hooks {
    using CreditLogic for CollateralDebtData;
    using SafeERC20 for IERC20;

    bytes32 internal constant MULTICALL_CONTEXT_STORAGE_SLOT = keccak256("credit.facade.v3.multicall.context");
    bytes32 internal constant LIQUIDATION_CONTEXT_STORAGE_SLOT = keccak256("credit.facade.v3.liquidation.context");

    modifier nonReentrantExecution() {
        if (_getMulticallContext().creditAccount != address(0)) revert("Reentrant execution");
        _;
    }

    modifier nonReentrantLiquidation() {
        if (_getLiquidationContext().creditAccount != address(0)) revert("Reentrant liquidation");
        _;
    }

    /// @dev Ensures that function caller is `creditAccount` itself
    modifier creditAccountOnly() {
        _checkCreditAccountOwner(msg.sender);
        _;
    }

    modifier onlyActiveCreditAccount() {
        if (_getMulticallContext().creditAccount != msg.sender) revert CallerNotCreditAccountOwnerException();
        _;
    }

    modifier onlyActiveCreditAccountOnLiquidation() {
        if (_getLiquidationContext().creditAccount != msg.sender) revert CallerNotCreditAccountOwnerException();
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

    function onBeforeExecution() external override nonReentrantExecution creditAccountOnly {
        _checkBeforeExecution(msg.sender);
    }

    function onAfterExecution() external override onlyActiveCreditAccount {
        _checkAfterExecution(msg.sender);
    }

    function onDemandPriceUpdates(PriceUpdate[] calldata /*updates*/ ) external override onlyActiveCreditAccount {
        _onDemandPriceUpdates(msg.data[4:]);
    }

    function storeExpectedBalances(BalanceDelta[] calldata balanceDeltas) external override onlyActiveCreditAccount {
        MulticallContext storage $context = _getMulticallContext();
        address creditAccount = $context.creditAccount;

        if ($context.expectedBalancesPacked.length != 0) revert ExpectedBalancesAlreadySetException();
        $context.expectedBalancesPacked = abi.encode(BalancesLogic.storeBalances(creditAccount, balanceDeltas));
    }

    function compareBalances() external override onlyActiveCreditAccount {
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
        onlyActiveCreditAccount
    {
        MulticallContext storage $context = _getMulticallContext();

        // _revertIfNoPermission($context.flags, UPDATE_QUOTA_PERMISSION);
        ($context.enabledTokensMask,) =
            _updateQuota($context.creditAccount, msg.data[4:], $context.enabledTokensMask, type(uint256).max);
    }

    function increaseDebt(uint256 amount) external override onlyActiveCreditAccount {
        MulticallContext storage $context = _getMulticallContext();
        _manageDebt(msg.sender, amount, $context.enabledTokensMask, ManageDebtAction.INCREASE_DEBT); // U:[FA-27]
    }

    function decreaseDebt(uint256 amount) external override onlyActiveCreditAccount {
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
        onlyActiveCreditAccount
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

    function _getLiquidationContext() internal pure returns (LiquidationContext storage $context) {
        bytes32 slot = LIQUIDATION_CONTEXT_STORAGE_SLOT;
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

    function onBeforeLiquidation(address creditAccount, address[] calldata tokens, uint256[] calldata values)
        external
        nonReentrantLiquidation
        creditAccountOnly
    {
        LiquidationContext storage $context = _getLiquidationContext();
        $context.creditAccount = creditAccount;

        (CollateralDebtData memory collateralDebtData, bool isUnhealthy) = _revertIfNotLiquidatable(creditAccount);
        bool isExpired = !isUnhealthy;
        bool hasBadDebt = _hasBadDebt(collateralDebtData);

        if (isUnhealthy && hasBadDebt) {
            ILossPolicy.Params memory params = ILossPolicy.Params({
                totalDebtUSD: collateralDebtData.totalDebtUSD,
                twvUSD: collateralDebtData.twvUSD,
                extraData: "" // lossPolicyData
            });
            if (!ILossPolicy(lossPolicy).isLiquidatableWithLoss(creditAccount, msg.sender, params)) {
                revert CreditAccountNotLiquidatableWithLossException(); // U:[FA-17]
            }
            maxDebtPerBlockMultiplier = 0; // U:[FA-17]
        }

        // address priceOracle = ICreditManagerV3(creditManager).priceOracle();
        uint256 valueToLiquidateInUnderlying = 0;
        for (uint256 i; i < tokens.length; i++) {
            uint256 tokenMask = _getTokenMaskOrRevert(tokens[i]);
            if (tokenMask & collateralDebtData.enabledTokensMask == 0 || tokens[i] == underlying) {
                revert TokenNotAllowedException();
            }

            (uint96 quota,) = IPoolQuotaKeeperV3(collateralDebtData._poolQuotaKeeper).getQuota(creditAccount, tokens[i]);
            uint16 lt = ICreditManagerV3(creditManager).liquidationThresholds(tokens[i]);
            uint256 maxValue = quota * PERCENTAGE_FACTOR / lt;
            if (values[i] > maxValue) {
                valueToLiquidateInUnderlying += maxValue;
            } else {
                valueToLiquidateInUnderlying += values[i];
            }
        }

        (
            ,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        ) = ICreditManagerV3(creditManager).fees();

        uint256 amountToLiquidator;
        uint256 feeAmount;
        if (isExpired) {
            amountToLiquidator =
                valueToLiquidateInUnderlying * (PERCENTAGE_FACTOR - liquidationDiscountExpired) / PERCENTAGE_FACTOR;
            feeAmount = valueToLiquidateInUnderlying * feeLiquidationExpired / PERCENTAGE_FACTOR;
        } else {
            amountToLiquidator =
                valueToLiquidateInUnderlying * (PERCENTAGE_FACTOR - liquidationDiscount) / PERCENTAGE_FACTOR;
            feeAmount = valueToLiquidateInUnderlying * feeLiquidation / PERCENTAGE_FACTOR;
        }

        uint256 underlyingBalance = IERC20(underlying).safeBalanceOf($context.creditAccount);

        $context.hasBadDebt = hasBadDebt;
        $context.maxFeeAmount = feeAmount;
        $context.minUnderlyingBalance = underlyingBalance + valueToLiquidateInUnderlying - amountToLiquidator;
        $context.collateralDebtDataPacked = abi.encode(collateralDebtData);
    }

    function onAfterLiquidation(address creditAccount) external onlyActiveCreditAccountOnLiquidation {
        LiquidationContext storage $context = _getLiquidationContext();
        CollateralDebtData memory cdd = abi.decode($context.collateralDebtDataPacked, (CollateralDebtData));
        uint256 totalDebt = cdd.calcTotalDebt();

        uint256 underlyingBalanceAfter = IERC20(underlying).safeBalanceOf(creditAccount);
        if (underlyingBalanceAfter < $context.minUnderlyingBalance) {
            revert InsufficientRemainingFundsException();
        }

        uint256 feeAmount;
        // TODO: add _amountWithFee / _amountMinusFee
        if (underlyingBalanceAfter < totalDebt && !$context.hasBadDebt) {
            uint256 amountToPool =
                Math.min(underlyingBalanceAfter - $context.maxFeeAmount, totalDebt - debtLimits.minDebt);
            feeAmount = $context.maxFeeAmount;
            _manageDebt(creditAccount, amountToPool, cdd.enabledTokensMask, ManageDebtAction.DECREASE_DEBT);
            _fullCollateralCheck({
                creditAccount: creditAccount,
                enabledTokensMask: cdd.enabledTokensMask,
                collateralHints: new uint256[](0),
                minHealthFactor: PERCENTAGE_FACTOR,
                useSafePrices: false
            });
        } else {
            (uint256 remainingFunds,) =
                ICreditManagerV3(creditManager).liquidateCreditAccount(creditAccount, cdd, address(0), false);

            feeAmount = Math.min(remainingFunds, $context.maxFeeAmount);
        }

        //TODO: transfer feeAmount to treasury
    }
}
