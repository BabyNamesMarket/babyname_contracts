#!/bin/bash
set -euo pipefail

source .env

STAGE="${DEPLOY_STAGE:-commit}"

# Use nightly foundry if available (handles Base Sepolia receipt format)
NIGHTLY_DIR="$HOME/.foundry/bin"
if [ -x "$NIGHTLY_DIR/forge" ]; then
  export PATH="$NIGHTLY_DIR:$PATH"
fi

# Live stage always deploys its own TestUSDC (deployer needs balance to seed markets)
if [ "$STAGE" = "commit" ]; then
  export COLLATERAL_TOKEN_ADDRESS="${COLLATERAL_TOKEN_ADDRESS:-${TOKEN_ADDRESS:-}}"
else
  unset COLLATERAL_TOKEN_ADDRESS
fi

case "$STAGE" in
  commit)
    SCRIPT="script/DeployTestnet.s.sol:DeployTestnet"
    ARTIFACT="deployments/84532.json"
    ;;
  live)
    SCRIPT="script/DeployTestnetLive.s.sol:DeployTestnetLive"
    ARTIFACT="deployments/84532-live.json"
    ;;
  *)
    echo "Unknown DEPLOY_STAGE: $STAGE (expected 'commit' or 'live')"
    exit 1
    ;;
esac

echo "Deploying stage: $STAGE"

EXTRA_FLAGS=""
# Live deploy uses timestamp-dependent proposalIds; skip on-chain simulation
# because forge replays txs with different block.timestamps, causing ID mismatch.
if [ "$STAGE" = "live" ]; then
  EXTRA_FLAGS="--skip-simulation --slow"
fi

set +e
forge script "$SCRIPT" \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  $EXTRA_FLAGS
STATUS=$?
set -e

if [ $STATUS -ne 0 ] && [ ! -f "$ARTIFACT" ]; then
  exit $STATUS
fi

DEPLOY_STAGE="$STAGE" node scripts/update-base-sepolia-metadata.js
