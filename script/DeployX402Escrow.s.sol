// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {X402Escrow} from "../src/X402Escrow.sol";

contract DeployX402Escrow is Script {
    function run() external {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address facilitator = vm.envAddress("FACILITATOR_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        X402Escrow impl = new X402Escrow();

        // 2. Deploy proxy and call initialize()
        bytes memory initData = abi.encodeCall(X402Escrow.initialize, (usdc, facilitator, admin, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();

        console.log("Implementation:", address(impl));
        console.log("Proxy (use this):", address(proxy));
        console.log("  usdc:       ", usdc);
        console.log("  facilitator:", facilitator);
        console.log("  admin:      ", admin);
        console.log("  owner:      ", owner);
    }
}
