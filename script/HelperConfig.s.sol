//SPDX - License - Identifier: MIT

pragma solidity ^0.8.18;

import {Script}  from  "forge-std/src/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUSDPriceFeed;
        address wbtcUSDPriceFeed;
        address weth;
        address wbtc;
        address deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {

    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory)  {
        return NetworkConfig({
            wethUSDPriceFeed: ,
        });
    }
}