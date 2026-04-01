// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {X402Escrow} from "../src/X402Escrow.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address existingProxy = vm.envOr("ESCROW_PROXY_ADDRESS", address(0));

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        X402Escrow impl = new X402Escrow();
        address proxyAddress;

        if (existingProxy == address(0)) {
            // 2a. Fresh deploy path: deploy proxy and call initialize()
            address usdc = vm.envAddress("USDC_ADDRESS");
            address owner = vm.envAddress("OWNER_ADDRESS");
            bytes memory initData = abi.encodeCall(X402Escrow.initialize, (usdc, owner));
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            proxyAddress = address(proxy);

            console.log("Mode: fresh deploy");
            console.log("  usdc: ", usdc);
            console.log("  owner:", owner);
        } else {
            // 2b. Upgrade path: keep proxy address, update implementation
            if (existingProxy.code.length == 0) {
                revert("ESCROW_PROXY_ADDRESS has no code");
            }
            X402Escrow(payable(existingProxy)).upgradeToAndCall(address(impl), bytes(""));
            proxyAddress = existingProxy;

            console.log("Mode: upgrade existing proxy");
            console.log("  proxy:", existingProxy);
        }

        vm.stopBroadcast();

        console.log("Implementation:", address(impl));
        console.log("Proxy (use this):", proxyAddress);
    }
}
