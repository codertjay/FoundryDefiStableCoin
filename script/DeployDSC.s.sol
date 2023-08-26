// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from  "forge-std/Script.sol";
import {DecentralizedStableCoin} from  "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";


contract DeployDSC is Script {
    function setUp() public {}

    function run() external returns (DecentralizedStableCoin, DSCEngine) {
        vm.broadcast();
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine();
        vm.stopBroadcast();
    }
}
