const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const STAGE = process.env.DEPLOY_STAGE || "commit";
const DEPLOYMENT_PATH = STAGE === "commit"
  ? path.join(ROOT, "deployments/84532.json")
  : path.join(ROOT, `deployments/84532-${STAGE}.json`);
const BROADCAST_SCRIPT = STAGE === "live" ? "DeployTestnetLive.s.sol" : "DeployTestnet.s.sol";
const BROADCAST_PATH = path.join(ROOT, `broadcast/${BROADCAST_SCRIPT}/84532/run-latest.json`);

function requireFile(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Missing required file: ${filePath}`);
  }
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + "\n");
}

function getCreateTxHash(broadcast, contractName, expectedAddress) {
  const tx = broadcast.transactions.find((entry) => {
    return entry.transactionType === "CREATE"
      && entry.contractName === contractName
      && entry.contractAddress
      && entry.contractAddress.toLowerCase() === expectedAddress.toLowerCase();
  });
  if (!tx) {
    throw new Error(`Missing CREATE tx for ${contractName} ${expectedAddress}`);
  }
  return tx.hash;
}

function getBlockNumber(txHash, rpcUrl) {
  let receipt;
  try {
    const out = execFileSync(
      "cast",
      ["receipt", txHash, "--json", "--rpc-url", rpcUrl],
      { encoding: "utf8" }
    );
    receipt = JSON.parse(out);
  } catch (error) {
    const stderr = error.stderr ? String(error.stderr) : "";
    const stdout = error.stdout ? String(error.stdout) : "";
    const combined = `${stdout}\n${stderr}`;
    const jsonStart = combined.indexOf("{");
    if (jsonStart === -1) throw error;
    receipt = JSON.parse(combined.slice(jsonStart));
  }
  const blockValue = receipt.blockNumber;
  return typeof blockValue === "string" ? Number(blockValue) : blockValue;
}

function main() {
  requireFile(DEPLOYMENT_PATH);
  requireFile(BROADCAST_PATH);

  const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
  const deployment = readJson(DEPLOYMENT_PATH);
  const broadcast = readJson(BROADCAST_PATH);

  const pmCreateTx = getCreateTxHash(broadcast, "PredictionMarket", deployment.PredictionMarket);
  const launchpadCreateTx = getCreateTxHash(broadcast, "Launchpad", deployment.Launchpad);
  const startBlock = Math.min(
    getBlockNumber(pmCreateTx, rpcUrl),
    getBlockNumber(launchpadCreateTx, rpcUrl)
  ) - 1;

  deployment.goldsky = {
    projectId: "project_cmnfucw0yiuar01y0347j7weu",
    subgraph: "babynames-market-base-sepolia/1.0.0",
    chain: "base-sepolia",
    endpoint:
      "https://api.goldsky.com/api/public/project_cmnfucw0yiuar01y0347j7weu/subgraphs/babynames-market-base-sepolia/1.0.0/gn",
    startBlock,
    abis: {
      PredictionMarket: "./abi/PredictionMarket.json",
      Launchpad: "./abi/Launchpad.json",
    },
    instances: [
      {
        abi: "PredictionMarket",
        address: deployment.PredictionMarket,
        startBlock,
        chain: "base-sepolia",
      },
      {
        abi: "Launchpad",
        address: deployment.Launchpad,
        startBlock,
        chain: "base-sepolia",
      },
    ],
  };

  writeJson(DEPLOYMENT_PATH, deployment);

  process.stdout.write(
    `Deployment metadata updated:\n`
      + `PredictionMarket=${deployment.PredictionMarket}\n`
      + `Launchpad=${deployment.Launchpad}\n`
      + `startBlock=${startBlock}\n`
      + `deployment=${DEPLOYMENT_PATH}\n`
  );
}

main();
