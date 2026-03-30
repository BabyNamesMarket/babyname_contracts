const fs = require("fs");
const path = require("path");

const PredictionMarketABI = require("./abi/PredictionMarket.json");
const LaunchpadABI = require("./abi/Launchpad.json");
const OutcomeTokenABI = require("./abi/OutcomeToken.json");
const RewardDistributorABI = require("./abi/RewardDistributor.json");

function getDeployment(chainId) {
  const filePath = path.join(__dirname, "deployments", `${chainId}.json`);
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
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
  RewardDistributorABI,
  getDeployment,
  CHAIN_IDS,
};
