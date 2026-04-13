// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/PredictionMarket.sol";
import "../src/Launchpad.sol";
import "../src/OutcomeToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal ERC20 for testnet deployments (open mint)
contract TestUSDC is ERC20 {
    function name() public pure override returns (string memory) {
        return "Test USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "tUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

        // 2. Deploy PredictionMarket
        PredictionMarket pm = new PredictionMarket();
        pm.initialize(collateralToken);
        // Set market creation fee to $5/outcome
        pm.grantRoles(deployer, pm.PROTOCOL_MANAGER_ROLE());
        pm.setMarketCreationFee(5e6);
        console.log("PredictionMarket:", address(pm));

        // 3. Deploy Launchpad
        //    - surplusRecipient = deployer (test treasury)
        //    - defaultOracle = deployer (manual resolution for testing)
        //    - defaultDeadlineDuration = 7 days
        Launchpad vault = new Launchpad(
            address(pm),
            deployer,       // surplusRecipient
            deployer,       // defaultOracle
            7 days,         // defaultDeadlineDuration
            deployer        // owner
        );
        console.log("Launchpad:", address(vault));

        // 4. Grant Launchpad the MARKET_CREATOR_ROLE on PredictionMarket
        pm.grantMarketCreatorRole(address(vault));

        // 5. Finalize testnet defaults.
        vault.seedDefaultRegions();
        vault.openYear(2025);
        vault.setYearLaunchDate(2025, block.timestamp + 7 days);
        console.log("Default regions seeded, year 2025 opened");

        // 6. Set names merkle roots from generated all-time gender-split data
        string memory rootsJson = vm.readFile("data/name-merkle-roots.json");
        bytes32 boysRoot = rootsJson.readBytes32(".boys.root");
        bytes32 girlsRoot = rootsJson.readBytes32(".girls.root");
        vault.setNamesMerkleRoot(Launchpad.Gender.BOY, boysRoot);
        vault.setNamesMerkleRoot(Launchpad.Gender.GIRL, girlsRoot);
        console.log("Names merkle roots set");

        vm.stopBroadcast();

        // Write deployment artifact
        string memory chainIdStr = vm.toString(block.chainid);
        string memory json = string.concat(
            '{"PredictionMarket":"', vm.toString(address(pm)),
            '","Launchpad":"', vm.toString(address(vault)),
            '","TestUSDC":"', vm.toString(collateralToken),
            '","CollateralToken":"', vm.toString(collateralToken),
            '","OutcomeTokenImpl":"', vm.toString(pm.outcomeTokenImplementation()),
            '","chainId":', chainIdStr,
            ',"deployer":"', vm.toString(deployer),
            '","oracle":"', vm.toString(deployer),
            '","surplusRecipient":"', vm.toString(deployer),
            '"}'
        );
        string memory path = string.concat("deployments/", chainIdStr, ".json");
        vm.writeFile(path, json);
        string memory commitPath = string.concat("deployments/", chainIdStr, "-commit.json");
        vm.writeFile(commitPath, json);
        console.log("Deployment artifact written to", path);
    }
}
