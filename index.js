const fs = require("fs");
const path = require("path");

const PredictionMarketABI = require("./abi/PredictionMarket.json");
const LaunchpadABI = require("./abi/Launchpad.json");
const OutcomeTokenABI = require("./abi/OutcomeToken.json");

function getDeployment(chainId) {
  const filePath = path.join(__dirname, "deployments", `${chainId}.json`);
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function getGoldskyConfig(chainId) {
  const deployment = getDeployment(chainId);
  return deployment && deployment.goldsky ? deployment.goldsky : null;
}

const CHAIN_IDS = {
  mainnet: 1,
  sepolia: 11155111,
  base: 8453,
  baseSepolia: 84532,
  tempo: 4217,
  tempoTestnet: 42431,
};

module.exports = {
  PredictionMarketABI,
  LaunchpadABI,
  OutcomeTokenABI,
  getDeployment,
  getGoldskyConfig,
  CHAIN_IDS,
};
