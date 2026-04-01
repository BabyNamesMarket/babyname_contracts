const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const FRONTEND_ROOT = path.resolve(ROOT, "../babynames_market");
const GOLDSKY_ROOT = path.join(FRONTEND_ROOT, "goldsky");
const DEPLOYMENT_PATH = path.join(ROOT, "deployments/84532.json");
const BROADCAST_PATH = path.join(ROOT, "broadcast/DeployTestnet.s.sol/84532/run-latest.json");
const GOLDSKY_CONFIG_PATH = path.join(GOLDSKY_ROOT, "goldsky.config.json");
const GOLDSKY_ABI_DIR = path.join(GOLDSKY_ROOT, "abis");

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

function copyAbi(name) {
  const src = path.join(ROOT, "abi", `${name}.json`);
  const dst = path.join(GOLDSKY_ABI_DIR, `${name}.json`);
  fs.copyFileSync(src, dst);
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

function syncConfig(startBlock, deployment) {
  const config = readJson(GOLDSKY_CONFIG_PATH);
  config.abis = {
    PredictionMarket: { path: "./abis/PredictionMarket.json" },
    Launchpad: { path: "./abis/Launchpad.json" },
  };
  config.chains = ["base-sepolia"];
  config.instances = [
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
  ];
  writeJson(GOLDSKY_CONFIG_PATH, config);
}

function maybeDeploySubgraph() {
  if (process.env.GOLDSKY_AUTO_DEPLOY !== "true") return;

  execFileSync(
    "goldsky",
    ["subgraph", "delete", "babynames-market-base-sepolia/1.0.0", "--force"],
    { cwd: FRONTEND_ROOT, stdio: "inherit" }
  );
  execFileSync(
    "goldsky",
    ["subgraph", "deploy", "babynames-market/1.0.0", "--from-abi", "goldsky/goldsky.config.json"],
    { cwd: FRONTEND_ROOT, stdio: "inherit" }
  );
}

function main() {
  requireFile(DEPLOYMENT_PATH);
  requireFile(BROADCAST_PATH);
  requireFile(GOLDSKY_CONFIG_PATH);
  requireFile(path.join(ROOT, "abi/PredictionMarket.json"));
  requireFile(path.join(ROOT, "abi/Launchpad.json"));
  fs.mkdirSync(GOLDSKY_ABI_DIR, { recursive: true });

  const rpcUrl = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
  const deployment = readJson(DEPLOYMENT_PATH);
  const broadcast = readJson(BROADCAST_PATH);

  copyAbi("PredictionMarket");
  copyAbi("Launchpad");

  const pmCreateTx = getCreateTxHash(broadcast, "PredictionMarket", deployment.PredictionMarket);
  const launchpadCreateTx = getCreateTxHash(broadcast, "Launchpad", deployment.Launchpad);
  const startBlock = Math.min(
    getBlockNumber(pmCreateTx, rpcUrl),
    getBlockNumber(launchpadCreateTx, rpcUrl)
  ) - 1;

  syncConfig(startBlock, deployment);
  maybeDeploySubgraph();

  process.stdout.write(
    `Goldsky synced:\n`
      + `PredictionMarket=${deployment.PredictionMarket}\n`
      + `Launchpad=${deployment.Launchpad}\n`
      + `startBlock=${startBlock}\n`
      + `config=${GOLDSKY_CONFIG_PATH}\n`
  );
}

main();
