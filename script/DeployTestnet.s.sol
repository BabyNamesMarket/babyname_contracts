// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PredictionMarket.sol";
import "../src/OutcomeToken.sol";
import "../src/TestUSDC.sol";
import "../src/MarketValidation.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract DeployTestnet is Script {
    using stdJson for string;

    function run() external virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address collateralToken = vm.envOr("COLLATERAL_TOKEN_ADDRESS", address(0));
        bool deployedTestToken = collateralToken == address(0);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Determine collateral token.
        IERC20 usdc;
        if (deployedTestToken) {
            TestUSDC testUsdc = new TestUSDC();
            testUsdc.mint(deployer, 10_000_000 * 1e6); // 10M tUSDC
            usdc = IERC20(address(testUsdc));
            collateralToken = address(testUsdc);
            console.log("TestUSDC:", collateralToken);
        } else {
            usdc = IERC20(collateralToken);
            console.log("CollateralToken:", collateralToken);
        }

        // 2. Deploy PredictionMarket (UUPS proxy)
        PredictionMarket pmImpl = new PredictionMarket();
        console.log("PredictionMarket impl:", address(pmImpl));
        address pmProxy = address(
            new ERC1967Proxy(
                address(pmImpl), abi.encodeCall(PredictionMarket.initialize, (collateralToken, address(0), deployer))
            )
        );
        PredictionMarket pm = PredictionMarket(pmProxy);
        MarketValidation validator = new MarketValidation(address(pm));
        pm.setValidation(address(validator));
        console.log("Validation:", address(validator));
        pm.grantRoles(deployer, pm.PROTOCOL_MANAGER_ROLE());
        console.log("PredictionMarket:", address(pm));

        // 3. Configure name market defaults
        pm.setDefaultOracle(deployer);
        pm.setDefaultSurplusRecipient(deployer);
        pm.seedDefaultRegions();
        pm.openYear(2025);
        console.log("Default regions seeded, year 2025 opened");

        // 4. Set names merkle roots from generated all-time gender-split data
        string memory rootsJson = vm.readFile("data/name-merkle-roots.json");
        bytes32 boysRoot = rootsJson.readBytes32(".boys.root");
        bytes32 girlsRoot = rootsJson.readBytes32(".girls.root");
        pm.setNamesMerkleRoot(PredictionMarket.Gender.BOY, boysRoot);
        pm.setNamesMerkleRoot(PredictionMarket.Gender.GIRL, girlsRoot);
        console.log("Names merkle roots set");

        // 5. Optionally seed sample markets from the sample proofs in the roots file.
        if (vm.envOr("SEED_SAMPLE_MARKETS", false)) {
            bytes32[] memory boysProof = rootsJson.readBytes32Array(".boys.sampleProof");
            bytes32[] memory girlsProof = rootsJson.readBytes32Array(".girls.sampleProof");

            usdc.approve(address(pm), type(uint256).max);

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 10e6;
            amounts[1] = 10e6;

            pm.createNameMarket("liam", 2025, PredictionMarket.Gender.BOY, boysProof, amounts);
            pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, girlsProof, amounts);
            console.log("Sample markets seeded");
        }

        vm.stopBroadcast();

        // Write deployment artifact
        string memory chainIdStr = vm.toString(block.chainid);
        string memory testUsdcJsonValue = deployedTestToken ? vm.toString(collateralToken) : "";
        string memory json = string.concat(
            '{"PredictionMarket":"',
            vm.toString(address(pm)),
            '","PredictionMarketImpl":"',
            vm.toString(address(pmImpl)),
            '","TestUSDC":"',
            testUsdcJsonValue,
            '","CollateralToken":"',
            vm.toString(collateralToken),
            '","OutcomeTokenImpl":"',
            vm.toString(pm.outcomeTokenImplementation()),
            '","Validation":"',
            vm.toString(address(validator)),
            '","chainId":',
            chainIdStr,
            ',"deployer":"',
            vm.toString(deployer),
            '","oracle":"',
            vm.toString(deployer),
            '","surplusRecipient":"',
            vm.toString(deployer),
            '"}'
        );
        string memory path = string.concat("deployments/", chainIdStr, ".json");
        vm.writeFile(path, json);
        console.log("Deployment artifact written to", path);
    }
}
