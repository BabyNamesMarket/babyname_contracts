#!/bin/bash
set -euo pipefail

set -a
source .env
set +a

# Use nightly foundry if available (handles Base Sepolia receipt format)
NIGHTLY_DIR="$HOME/.foundry/bin"
if [ -x "$NIGHTLY_DIR/forge" ]; then
  export PATH="$NIGHTLY_DIR:$PATH"
fi

SCRIPT="script/DeployTestnet.s.sol:DeployTestnet"
ARTIFACT="deployments/84532.json"

# Base Sepolia should always get a fresh mintable TestUSDC unless the caller
# explicitly overrides the token address for a one-off deployment.
if [ -n "${COLLATERAL_TOKEN_ADDRESS:-}" ]; then
  echo "Using explicit collateral token: $COLLATERAL_TOKEN_ADDRESS"
else
  echo "Deploying fresh TestUSDC for Base Sepolia"
fi

set +e
forge script "$SCRIPT" \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --slow
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  exit $STATUS
fi

node scripts/update-base-sepolia-metadata.js
node scripts/verify-base-sepolia.js
node scripts/publish-base-sepolia-goldsky.js
