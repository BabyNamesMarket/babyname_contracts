const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const DEPLOYMENT_PATH = path.join(ROOT, "deployments/84532.json");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function contractSettings(artifactPath) {
  const artifact = readJson(artifactPath);
  return {
    compilerVersion: `v${artifact.metadata.compiler.version}`,
    optimizerRuns: artifact.metadata.settings.optimizer.runs,
    viaIR: Boolean(artifact.metadata.settings.viaIR),
  };
}

function verify(address, contractPath, artifactPath) {
  const { compilerVersion, optimizerRuns, viaIR } = contractSettings(artifactPath);
  const args = [
    "verify-contract",
    "--chain-id", "84532",
    "--compiler-version", compilerVersion,
    "--num-of-optimizations", String(optimizerRuns),
    "--watch",
    address,
    contractPath,
    "--etherscan-api-key", process.env.ETHERSCAN_API_KEY,
  ];

  if (viaIR) args.splice(8, 0, "--via-ir");

  execFileSync("forge", args, {
    cwd: ROOT,
    stdio: "inherit",
    env: process.env,
  });
}

function main() {
  if (!process.env.ETHERSCAN_API_KEY) {
    throw new Error("ETHERSCAN_API_KEY is required for verification");
  }
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    throw new Error(`Missing deployment artifact: ${DEPLOYMENT_PATH}`);
  }

  const deployment = readJson(DEPLOYMENT_PATH);

  if (deployment.TestUSDC) {
    verify(
      deployment.TestUSDC,
      "src/TestUSDC.sol:TestUSDC",
      path.join(ROOT, "out/TestUSDC.sol/TestUSDC.json"),
    );
  }

  if (deployment.Validation) {
    verify(
      deployment.Validation,
      "src/MarketValidation.sol:MarketValidation",
      path.join(ROOT, "out/MarketValidation.sol/MarketValidation.json"),
    );
  }

  verify(
    deployment.PredictionMarketImpl,
    "src/PredictionMarket.sol:PredictionMarket",
    path.join(ROOT, "out/PredictionMarket.sol/PredictionMarket.json"),
  );

  verify(
    deployment.OutcomeTokenImpl,
    "src/OutcomeToken.sol:OutcomeToken",
    path.join(ROOT, "out/OutcomeToken.sol/OutcomeToken.json"),
  );
}

main();
