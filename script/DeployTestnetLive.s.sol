// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "../src/PredictionMarket.sol";
import "../src/Launchpad.sol";
import "../src/OutcomeToken.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DeployTestnet, TestUSDC} from "./DeployTestnet.s.sol";

/**
 * @notice Deploys the full stack, proposes seed names with commits, and writes
 *         the deployment artifact. A post-deploy bash step (in deploy-base-sepolia.sh)
 *         sets the launch date to the past and calls launchMarket with actual
 *         on-chain proposalIds, because forge broadcasts each tx in a different
 *         block (different block.timestamp), making proposalIds computed in
 *         the script VM diverge from the on-chain ones.
 */
contract DeployTestnetLive is DeployTestnet {
    using stdJson for string;

    struct SeedName {
        string name;
        Launchpad.Gender gender;
        bytes32[] proof;
    }

    function run() external override {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address collateralToken = vm.envOr("COLLATERAL_TOKEN_ADDRESS", address(0));

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Stage: live");

        vm.startBroadcast(deployerPrivateKey);

        // --- Base deploy (same as commit stage) ---

        IERC20 usdc;
        if (collateralToken == address(0)) {
            TestUSDC testUsdc = new TestUSDC();
            testUsdc.mint(deployer, 10_000_000 * 1e6);
            usdc = IERC20(address(testUsdc));
            collateralToken = address(testUsdc);
            console.log("TestUSDC:", collateralToken);
        } else {
            usdc = IERC20(collateralToken);
            console.log("CollateralToken:", collateralToken);
        }

        PredictionMarket pm = new PredictionMarket();
        pm.initialize(collateralToken);
        pm.grantRoles(deployer, pm.PROTOCOL_MANAGER_ROLE());
        pm.setMarketCreationFee(5e6);
        console.log("PredictionMarket:", address(pm));

        Launchpad vault = new Launchpad(
            address(pm),
            deployer,
            deployer,
            7 days,
            deployer
        );
        console.log("Launchpad:", address(vault));

        pm.grantMarketCreatorRole(address(vault));

        vault.seedDefaultRegions();
        vault.openYear(2025);
        // Set launch date in the future so proposals enter the commit phase
        vault.setYearLaunchDate(2025, block.timestamp + 7 days);
        console.log("Default regions seeded, year 2025 opened");

        // Set merkle roots
        string memory rootsJson = vm.readFile("data/name-merkle-roots.json");
        bytes32 boysRoot = rootsJson.readBytes32(".boys.root");
        bytes32 girlsRoot = rootsJson.readBytes32(".girls.root");
        vault.setNamesMerkleRoot(Launchpad.Gender.BOY, boysRoot);
        vault.setNamesMerkleRoot(Launchpad.Gender.GIRL, girlsRoot);
        console.log("Names merkle roots set");

        // --- Seed proposals during commit phase ---

        SeedName[] memory seeds = _loadSeeds(rootsJson);

        // Approve Launchpad to pull USDC for proposals
        usdc.approve(address(vault), type(uint256).max);

        uint256 commitPerSide = 10e6; // $10 per side

        for (uint256 i; i < seeds.length; i++) {
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = commitPerSide;
            amounts[1] = commitPerSide;

            vault.propose(
                seeds[i].name,
                2025,
                seeds[i].gender,
                seeds[i].proof,
                amounts
            );
            console.log("Proposed:", seeds[i].name);
        }

        // NOTE: launchMarket is called post-deploy via cast because proposalIds
        // depend on block.timestamp which differs per broadcast transaction.

        vm.stopBroadcast();

        // Write deployment artifact
        _writeArtifact(address(pm), address(vault), collateralToken, deployer);
    }

    function _loadSeeds(string memory rootsJson) internal pure returns (SeedName[] memory seeds) {
        // Use the sample proofs from name-merkle-roots.json
        seeds = new SeedName[](2);

        // Liam (boy)
        bytes32[] memory boysProof = rootsJson.readBytes32Array(".boys.sampleProof");
        seeds[0] = SeedName({
            name: "liam",
            gender: Launchpad.Gender.BOY,
            proof: boysProof
        });

        // Olivia (girl)
        bytes32[] memory girlsProof = rootsJson.readBytes32Array(".girls.sampleProof");
        seeds[1] = SeedName({
            name: "olivia",
            gender: Launchpad.Gender.GIRL,
            proof: girlsProof
        });
    }

    function _writeArtifact(
        address pm,
        address vault,
        address collateralToken,
        address deployer
    ) internal {
        string memory chainIdStr = vm.toString(block.chainid);
        string memory json = string.concat(
            '{"PredictionMarket":"', vm.toString(pm),
            '","Launchpad":"', vm.toString(vault),
            '","TestUSDC":"', vm.toString(collateralToken),
            '","CollateralToken":"', vm.toString(collateralToken),
            '","OutcomeTokenImpl":"', vm.toString(PredictionMarket(pm).outcomeTokenImplementation()),
            '","chainId":', chainIdStr,
            ',"deployer":"', vm.toString(deployer),
            '","oracle":"', vm.toString(deployer),
            '","surplusRecipient":"', vm.toString(deployer),
            '","stage":"live"}'
        );
        string memory path = string.concat("deployments/", chainIdStr, "-live.json");
        vm.writeFile(path, json);
        console.log("Deployment artifact written to", path);
    }
}
