// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../../src/BetSlipSVG.sol";
import "../../src/BetSlipLogo.sol";
import "../../src/interfaces/IBetSlipRenderer.sol";

/**
 * @notice Generates SVG previews by calling the actual BetSlipSVG contract.
 *         Writes data URIs to previews/*.uri which are then decoded by the
 *         companion Node script.
 *
 * Usage: forge script scripts/preview/GeneratePreviews.s.sol
 */
contract GeneratePreviews is Script {
    function run() external {
        BetSlipLogo logoContract = new BetSlipLogo();
        BetSlipSVG renderer = new BetSlipSVG(address(logoContract));

        // ── Active single bet ────────────────────────────────────────
        _generate(renderer, "active-single-bet", IBetSlipRenderer.SlipData({
            tokenId:            1,
            poolName:           "Olivia",
            year:               2025,
            categoryType:       0,
            gender:             0,
            position:           1,
            amount:             5e18,
            tokenDecimals:      6,
            purchasedAt:        1735689600,
            deadline:           1746748800,
            currentTime:        1738368000,
            poolCollateral:     15e18,
            categoryCollateral: 120e18,
            resolved:           false,
            won:                false
        }));

        // ── Won top-N bet ────────────────────────────────────────────
        _generate(renderer, "won-topn-bet", IBetSlipRenderer.SlipData({
            tokenId:            42,
            poolName:           "Theo",
            year:               2025,
            categoryType:       3,
            gender:             1,
            position:           10,
            amount:             10e18,
            tokenDecimals:      6,
            purchasedAt:        1735689600,
            deadline:           1746748800,
            currentTime:        1749340800,
            poolCollateral:     30e18,
            categoryCollateral: 240e18,
            resolved:           true,
            won:                true
        }));

        // ── Lost exacta bet ─────────────────────────────────────────
        _generate(renderer, "lost-exacta-bet", IBetSlipRenderer.SlipData({
            tokenId:            7,
            poolName:           "Charlotte",
            year:               2025,
            categoryType:       1,
            gender:             0,
            position:           2,
            amount:             25e18,
            tokenDecimals:      6,
            purchasedAt:        1735689600,
            deadline:           1746748800,
            currentTime:        1749340800,
            poolCollateral:     50e18,
            categoryCollateral: 200e18,
            resolved:           true,
            won:                false
        }));

        // ── Closed trifecta bet ─────────────────────────────────────
        _generate(renderer, "closed-trifecta-bet", IBetSlipRenderer.SlipData({
            tokenId:            99,
            poolName:           "Emma",
            year:               2025,
            categoryType:       2,
            gender:             0,
            position:           3,
            amount:             1e18,
            tokenDecimals:      6,
            purchasedAt:        1735689600,
            deadline:           1741132800,
            currentTime:        1746748800,
            poolCollateral:     5e18,
            categoryCollateral: 50e18,
            resolved:           false,
            won:                false
        }));

        console.log("All previews generated.");
    }

    function _generate(
        BetSlipSVG renderer,
        string memory name,
        IBetSlipRenderer.SlipData memory d
    ) internal {
        string memory dataUri = renderer.renderTokenURI(d);
        string memory filePath = string.concat("previews/", name, ".uri");
        vm.writeFile(filePath, dataUri);
        console.log(string.concat("Generated: ", filePath));
    }
}
