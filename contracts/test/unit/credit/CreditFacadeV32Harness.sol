// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import "../../../interfaces/ICreditFacadeV3.sol";
import {CreditFacadeV3_Multicall} from "../../../credit/CreditFacadeV3_Multicall.sol";
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {ManageDebtAction, CollateralDebtData} from "../../../interfaces/ICreditManagerV3.sol";
import {BalanceWithMask} from "../../../libraries/BalancesLogic.sol";
import {RevertReasonForwarder} from "@1inch/solidity-utils/contracts/libraries/RevertReasonForwarder.sol";
import {LiquidationContext} from "../../../credit/CreditFacadeV3_Multicall.sol";
import {Vm} from "forge-std/Vm.sol";

contract CreditFacadeV32Harness is CreditFacadeV3_Multicall {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    constructor(
        address _addressProvider,
        address _creditManager,
        address _lossPolicy,
        address _botList,
        address _weth,
        address _degenNFT,
        bool _expirable
    ) CreditFacadeV3_Multicall(_addressProvider, _creditManager, _lossPolicy, _botList, _weth, _degenNFT, _expirable) {}

    function setReentrancy(uint8 _status) external {
        _reentrancyStatus = _status;
    }

    function multicallInt(address creditAccount, MultiCall[] calldata calls, uint256 enabledTokensMask, uint256 flags)
        external
    {
        CreditManagerMock(address(creditManager)).setEnabledTokensMask(enabledTokensMask);

        vm.startPrank(creditAccount);
        _checkBeforeExecution(creditAccount);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = address(calls[i].target).call(calls[i].callData);
            if (!success) {
                vm.stopPrank();
                // bubble up revert reason
                assembly ("memory-safe") {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
        }
        _checkAfterExecution(creditAccount);
        vm.stopPrank();
    }

    function revertIfNoPermission(uint256 flags, uint256 permission) external pure {
        _revertIfNoPermission(flags, permission);
    }

    function revertIfOutOfDebtPerBlockLimit(uint256 amount) external {
        _revertIfOutOfDebtPerBlockLimit(amount);
    }

    function revertIfNotLiquidatable(address creditAccount) external view returns (CollateralDebtData memory, bool) {
        return _revertIfNotLiquidatable(creditAccount);
    }

    function calcPartialLiquidationPayments(uint256 amount, address token, bool isExpired)
        external
        view
        returns (uint256, uint256, uint256)
    {
        return _calcPartialLiquidationPayments(amount, token, isExpired);
    }

    function setLastBlockBorrowed(uint64 _lastBlockBorrowed) external {
        lastBlockBorrowed = _lastBlockBorrowed;
    }

    function setTotalBorrowedInBlock(uint128 _totalBorrowedInBlock) external {
        totalBorrowedInBlock = _totalBorrowedInBlock;
    }

    function lastBlockBorrowedInt() external view returns (uint64) {
        return lastBlockBorrowed;
    }

    function totalBorrowedInBlockInt() external view returns (uint128) {
        return totalBorrowedInBlock;
    }

    function revertIfOutOfDebtLimits(uint256 debt, ManageDebtAction action) external view {
        _revertIfOutOfDebtLimits(debt, action);
    }

    function isExpiredInt() external view returns (bool) {
        return _isExpired();
    }

    // context

    function setLiquidationContext(LiquidationContext memory context) external {
        LiquidationContext storage $context = _getLiquidationContext();
        $context.creditAccount = context.creditAccount;
        $context.maxFeeAmount = context.maxFeeAmount;
        $context.minUnderlyingBalance = context.minUnderlyingBalance;
        $context.collateralDebtDataPacked = context.collateralDebtDataPacked;
        $context.hasBadDebt = context.hasBadDebt;
    }

    function getLiquidationContext() external view returns (LiquidationContext memory) {
        return _getLiquidationContext();
    }
}
