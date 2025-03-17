// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.17;

// Core imports
import {TestHelper} from "../../lib/helper.sol";
import {BalanceHelper} from "../../helpers/BalanceHelper.sol";
import {DUMB_ADDRESS, DEFAULT_FEE_LIQUIDATION, DEFAULT_LIQUIDATION_PREMIUM} from "../../lib/constants.sol";
import {PERCENTAGE_FACTOR} from "../../../libraries/Constants.sol";
import "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

// Interfaces
import {ICreditFacadeV3Events} from "../../../interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3, CollateralDebtData, ManageDebtAction} from "../../../interfaces/ICreditManagerV3.sol";
import {AP_BOT_LIST, AP_PRICE_ORACLE} from "../../interfaces/IAddressProviderV3.sol";

// Contract implementations
import {CreditFacadeV32Harness} from "./CreditFacadeV32Harness.sol";
import {LiquidationContext} from "../../../credit/CreditFacadeV3_Multicall.sol";

// Mocks
import {CreditManagerMock} from "../../mocks/credit/CreditManagerMock.sol";
import {AddressProviderV3ACLMock} from "../../mocks/core/AddressProviderV3ACLMock.sol";
import {PoolMock} from "../../mocks/pool/PoolMock.sol";
import {PriceOracleMock} from "../../mocks/oracles/PriceOracleMock.sol";
import {BotListMock} from "../../mocks/core/BotListMock.sol";
import {LossPolicyMock} from "../../mocks/core/LossPolicyMock.sol";
import {PoolQuotaKeeperMock} from "../../mocks/pool/PoolQuotaKeeperMock.sol";

// Test suites
import {TokensTestSuite} from "../../suites/TokensTestSuite.sol";

// Debugging
import {console} from "forge-std/console.sol";

contract CreditFacadeV32LiquidationUnitTest is TestHelper, BalanceHelper, ICreditFacadeV3Events {
    CreditFacadeV32Harness creditFacade;
    CreditManagerMock creditManagerMock;
    AddressProviderV3ACLMock addressProvider;
    LossPolicyMock lossPolicyMock;
    PoolQuotaKeeperMock poolQuotaKeeperMock;
    PriceOracleMock priceOracleMock;
    address treasury;
    // PriceOracleMock priceOracleMock;

    function setUp() public {
        tokenTestSuite = new TokensTestSuite();
        // tokenTestSuite.topUpWETH{value: 100 * WAD}();

        addressProvider = new AddressProviderV3ACLMock();
        PoolMock poolMock = new PoolMock(address(addressProvider), tokenTestSuite.addressOf(TOKEN_DAI));
        treasury = makeAddr("TREASURY");
        poolMock.setTreasury(treasury);
        creditManagerMock =
            new CreditManagerMock({_addressProvider: address(addressProvider), _pool: address(poolMock)});

        address botListMock = addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_10);
        lossPolicyMock = new LossPolicyMock();
        poolQuotaKeeperMock = new PoolQuotaKeeperMock(address(poolMock), tokenTestSuite.addressOf(TOKEN_DAI));

        creditFacade = new CreditFacadeV32Harness(
            address(addressProvider),
            address(creditManagerMock),
            address(lossPolicyMock), // without LossPolicy
            address(botListMock), // without BotList
            tokenTestSuite.addressOf(TOKEN_WETH),
            address(0), // without DegenNFT
            false // not expirable
        );

        priceOracleMock = PriceOracleMock(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_10));

        creditManagerMock.setCreditFacade(address(creditFacade));
        creditManagerMock.setPriceOracle(address(priceOracleMock));
    }

    // onBeforeLiquidation

    // function test_onBeforeLiquidation_reverts_if_credit_account_is_healthy() public {}
    // function test_onBeforeLiquidation_reverts_for_non_credit_account() public {}
    // function test_onBeforeLiquidation_reverts_if_token_is_not_enabled() public {}
    // function test_onBeforeLiquidation_reverts_if_token_is_underlying() public {}

    function test_onBeforeLiquidation_calculates_correct_liquidation_fees_and_values() public {
        // unhealthy account
        // expired account
        // account with bad debt
        address creditAccount = DUMB_ADDRESS;
        creditManagerMock.setBorrower(creditAccount);

        address dai = tokenTestSuite.addressOf(TOKEN_DAI);
        address link = tokenTestSuite.addressOf(TOKEN_LINK);

        // unhealthy account
        {
            uint16 linkLT = 9000;
            creditManagerMock.setLiquidationThresholds(link, linkLT);
            creditManagerMock.addToken(link, 2);

            // set account quotas
            poolQuotaKeeperMock.set_accountQuota(100, 0);
            // set account balances
            deal(link, creditAccount, 200);
            // set requested values
            address[] memory tokens = new address[](1);
            tokens[0] = link;
            uint256[] memory values = new uint256[](1);
            values[0] = 100;
            // set debt and collateral data
            CollateralDebtData memory cdd;
            cdd.debt = 101;
            cdd.totalDebtUSD = 101;
            cdd.twvUSD = 100;
            cdd.enabledTokensMask = 2;
            cdd._poolQuotaKeeper = address(poolQuotaKeeperMock);
            creditManagerMock.setDebtAndCollateralData(cdd);

            uint256 expectedMinUnderlyingBalance = 0 + 100 - 100 * DEFAULT_LIQUIDATION_PREMIUM / PERCENTAGE_FACTOR;
            uint256 expectedFeeAmount = 100 * DEFAULT_FEE_LIQUIDATION / PERCENTAGE_FACTOR;

            creditFacade.onBeforeLiquidation(creditAccount, tokens, values);

            LiquidationContext memory context = creditFacade.getLiquidationContext();
            assertEq(context.minUnderlyingBalance, expectedMinUnderlyingBalance);
            assertEq(context.maxFeeAmount, expectedFeeAmount);
        }

        // expired account

        // requested more than quota

        // account with bad debt
    }

    function test_onAfterLiquidation_works_as_expected() public {
        address creditAccount = DUMB_ADDRESS;

        address dai = tokenTestSuite.addressOf(TOKEN_DAI);
        address link = tokenTestSuite.addressOf(TOKEN_LINK);

        // underlying balance less than (valueToLiquidate - amountToLiquidator) after liquidation

        // underlying balance more than total debt after liquidation
        {
            CollateralDebtData memory cdd;
            // total debt = 100
            cdd.debt = 100;
            cdd.accruedFees = 0;
            cdd.accruedInterest = 0;
            cdd.totalDebtUSD = 100;

            // underlying balance = 101
            deal(dai, creditAccount, 101);

            // context
            LiquidationContext memory context;
            context.creditAccount = creditAccount;
            context.maxFeeAmount = 0;
            context.minUnderlyingBalance = 101;
            context.collateralDebtDataPacked = abi.encode(cdd);
            context.hasBadDebt = false;
            creditFacade.setLiquidationContext(context);

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(ICreditManagerV3.liquidateCreditAccount, (creditAccount, cdd, address(0), false))
            );
            creditFacade.onAfterLiquidation(creditAccount);
        }

        // underlying balance less than total debt after liquidation
        {
            CollateralDebtData memory cdd;
            // total debt = 100
            cdd.debt = 100;
            cdd.accruedFees = 0;
            cdd.accruedInterest = 0;
            cdd.totalDebtUSD = 100;
            cdd.enabledTokensMask = 2;

            // underlying balance = 90 (less than total debt)
            deal(dai, creditAccount, 90);

            // context
            LiquidationContext memory context;
            context.creditAccount = creditAccount;
            context.maxFeeAmount = 0;
            context.minUnderlyingBalance = 90;
            context.collateralDebtDataPacked = abi.encode(cdd);
            context.hasBadDebt = false;
            creditFacade.setLiquidationContext(context);

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(ICreditManagerV3.manageDebt, (creditAccount, 90, 2, ManageDebtAction.DECREASE_DEBT))
            );
            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(
                    ICreditManagerV3.fullCollateralCheck,
                    (creditAccount, 1 | 2, new uint256[](0), PERCENTAGE_FACTOR, false)
                )
            );
            creditFacade.onAfterLiquidation(creditAccount);
        }

        // credit account has bad debt
        {
            CollateralDebtData memory cdd;
            // total debt = 100
            cdd.debt = 100;
            cdd.accruedFees = 0;
            cdd.accruedInterest = 0;
            cdd.totalDebtUSD = 100;
            cdd.enabledTokensMask = 2;

            // underlying balance = 90 (less than total debt)
            deal(dai, creditAccount, 90);

            // context
            LiquidationContext memory context;
            context.creditAccount = creditAccount;
            context.maxFeeAmount = 0;
            context.minUnderlyingBalance = 90;
            context.collateralDebtDataPacked = abi.encode(cdd);
            context.hasBadDebt = true;
            creditFacade.setLiquidationContext(context);

            vm.expectCall(
                address(creditManagerMock),
                abi.encodeCall(ICreditManagerV3.liquidateCreditAccount, (creditAccount, cdd, address(0), false))
            );
            creditFacade.onAfterLiquidation(creditAccount);
        }
    }
}
