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

# --- Post-deploy: launch markets for live stage ---
if [ "$STAGE" = "live" ]; then
  LAUNCHPAD=$(python3 -c "import json; d=json.load(open('$ARTIFACT')); print(d['Launchpad'])")
  echo "Launchpad: $LAUNCHPAD"

  # Set year launch date to 1 (past) so markets become launchable
  echo "Setting year launch date to past..."
  cast send "$LAUNCHPAD" \
    "setYearLaunchDate(uint16,uint256)" 2025 1 \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY"
  sleep 3

  # Extract proposalIds from broadcast receipts (ProposalCreated events)
  BROADCAST_FILE="broadcast/DeployTestnetLive.s.sol/84532/run-latest.json"
  TOPIC0=$(cast keccak "ProposalCreated(bytes32,bytes32,string,uint8,uint16,string,address,uint256)")

  PROPOSAL_IDS=$(python3 -c "
import json, sys
data = json.load(open('$BROADCAST_FILE'))
topic0 = '$TOPIC0'.lower()
for r in data.get('receipts', []):
    for log in r.get('logs', []):
        topics = log.get('topics', [])
        if len(topics) > 1 and topics[0].lower() == topic0:
            print(topics[1])
")

  if [ -z "$PROPOSAL_IDS" ]; then
    echo "WARNING: Could not find proposalIds in receipts."
    echo "Markets will launch lazily on first buy() or claimShares() call."
  else
    echo "Launching markets..."
    for PID in $PROPOSAL_IDS; do
      echo "  Launching $PID"
      cast send "$LAUNCHPAD" \
        "launchMarket(bytes32)" "$PID" \
        --rpc-url "$BASE_SEPOLIA_RPC_URL" \
        --private-key "$PRIVATE_KEY" || \
        echo "  (failed — will launch lazily on first interaction)"
      sleep 2
    done
    echo "Markets launched."
  fi
fi

DEPLOY_STAGE="$STAGE" node scripts/update-base-sepolia-metadata.js
