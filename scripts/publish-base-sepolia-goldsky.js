const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const DEPLOYMENT_PATH = path.join(ROOT, "deployments/84532.json");
const GENERATED_DIR = path.join(ROOT, ".goldsky");
const CONFIG_PATH = path.join(GENERATED_DIR, "base-sepolia-subgraph.json");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function requireDeployment() {
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    throw new Error(`Missing deployment artifact: ${DEPLOYMENT_PATH}`);
  }

  const deployment = readJson(DEPLOYMENT_PATH);
  if (!deployment.goldsky) {
    throw new Error(`Missing goldsky metadata in deployment artifact: ${DEPLOYMENT_PATH}`);
  }
  if (!deployment.PredictionMarket) {
    throw new Error(`Missing PredictionMarket address in deployment artifact: ${DEPLOYMENT_PATH}`);
  }

  return deployment;
}

function getPublishSubgraph(deployment) {
  const configured = deployment.goldsky.subgraph;
  const slashIndex = configured.lastIndexOf("/");
  if (slashIndex === -1) {
    throw new Error(`Invalid Goldsky subgraph slug: ${configured}`);
  }

  const name = configured.slice(0, slashIndex);
  const version = configured.slice(slashIndex + 1);
  const chainSuffix = `-${deployment.goldsky.chain}`;
  const publishName = name.endsWith(chainSuffix) ? name.slice(0, -chainSuffix.length) : name;
  return `${publishName}/${version}`;
}

function subgraphExists(nameAndVersion) {
  try {
    const output = execFileSync(
      "goldsky",
      ["subgraph", "list", nameAndVersion],
      {
        cwd: ROOT,
        env: process.env,
        encoding: "utf8",
      }
    );
    return output.includes(nameAndVersion);
  } catch (error) {
    return false;
  }
}

function deleteIfExists(nameAndVersion) {
  if (!subgraphExists(nameAndVersion)) return;
  execFileSync(
    "goldsky",
    ["subgraph", "delete", nameAndVersion, "-f"],
    {
      cwd: ROOT,
      stdio: "inherit",
      env: process.env,
    }
  );
}

function buildConfig(deployment) {
  const abiPath = path.relative(GENERATED_DIR, path.join(ROOT, "abi/PredictionMarket.json"));
  return {
    version: "1",
    name: deployment.goldsky.subgraph,
    abis: {
      PredictionMarket: {
        path: `./${abiPath}`,
      },
    },
    instances: [
      {
        abi: "PredictionMarket",
        address: deployment.PredictionMarket,
        startBlock: deployment.goldsky.startBlock,
        chain: deployment.goldsky.chain,
      },
    ],
  };
}

function main() {
  const deployment = requireDeployment();
  const subgraph = getPublishSubgraph(deployment);
  fs.mkdirSync(GENERATED_DIR, { recursive: true });
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(buildConfig(deployment), null, 2) + "\n");
  deleteIfExists(deployment.goldsky.subgraph);

  execFileSync(
    "goldsky",
    ["subgraph", "deploy", subgraph, "--from-abi", CONFIG_PATH],
    {
      cwd: ROOT,
      stdio: "inherit",
      env: process.env,
    }
  );
}

main();
