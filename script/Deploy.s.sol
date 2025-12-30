// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MilestoneFunding.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        MilestoneFunding mf = new MilestoneFunding();
        console.log("Deployed MilestoneFunding at:", address(mf));

        vm.stopBroadcast();

    }
}
