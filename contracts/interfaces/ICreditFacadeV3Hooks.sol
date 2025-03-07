// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

interface ICreditFacadeV3Hooks {
    function onBeforeExecution() external;
    function onAfterExecution() external;
}
