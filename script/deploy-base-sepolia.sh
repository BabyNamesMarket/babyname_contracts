#!/bin/bash
set -euo pipefail

source .env

export COLLATERAL_TOKEN_ADDRESS="${COLLATERAL_TOKEN_ADDRESS:-${TOKEN_ADDRESS:-}}"

set +e
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
STATUS=$?
set -e

if [ $STATUS -ne 0 ] && [ ! -f "deployments/84532.json" ]; then
  exit $STATUS
fi

node scripts/sync-goldsky-base-sepolia.js
