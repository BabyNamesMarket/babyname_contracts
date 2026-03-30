#!/bin/bash
# Deploy prediction market contracts to Tempo testnet (Moderato).
# Native Tempo TIP-20 setup is done post-deploy with `cast send` because
# `forge script` currently misbehaves when the script itself calls those precompiles.
set -euo pipefail

source .env

RPC="${RPC_URL:-https://rpc.moderato.tempo.xyz}"
SCRIPT="script/DeployTestnet.s.sol:DeployTestnet"
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
AUTO_FUND_FEE_SOURCE="${AUTO_FUND_FEE_SOURCE:-true}"
OPEN_YEAR="${OPEN_YEAR:-2025}"
INITIAL_FEE_SOURCE_FUNDS="${INITIAL_FEE_SOURCE_FUNDS:-500000000}"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
ARTIFACT="deployments/${CHAIN_ID}.json"
DEFAULT_LAUNCH_THRESHOLD="${DEFAULT_LAUNCH_THRESHOLD:-20000000}"
DEFAULT_DEADLINE_DURATION="${DEFAULT_DEADLINE_DURATION:-604800}"
MARKET_CREATION_FEE="${MARKET_CREATION_FEE:-5000000}"
FEE_SOURCE="${FEE_SOURCE:-$DEPLOYER}"
PM_GAS_LIMIT="${PM_GAS_LIMIT:-30000000}"
VAULT_GAS_LIMIT="${VAULT_GAS_LIMIT:-8000000}"
RD_GAS_LIMIT="${RD_GAS_LIMIT:-5000000}"

echo "Deploying via forge script: $SCRIPT"
echo "RPC: $RPC"
echo "Deployer: $DEPLOYER"

if [ "$FEE_SOURCE" != "$DEPLOYER" ]; then
  echo "FEE_SOURCE_MUST_BE_DEPLOYER for this wrapper" >&2
  exit 1
fi

if [ -n "${COLLATERAL_TOKEN_ADDRESS:-}" ] && [ "$AUTO_FUND_FEE_SOURCE" = "true" ]; then
  echo "Requesting Tempo faucet funding for deployer before external-token deployment..."
  cast rpc tempo_fundAddress "$DEPLOYER" --rpc-url "$RPC" >/dev/null
fi

if [ -n "${COLLATERAL_TOKEN_ADDRESS:-}" ]; then
  echo "Using manual deployment flow for native Tempo collateral."

  deploy_contract() {
    local contract="$1"
    local gas_limit="$2"
    shift 2 || true
    local output
    local address
    local code
    output=$(forge create "$contract" \
      --broadcast \
      --gas-limit "$gas_limit" \
      --rpc-url "$RPC" \
      --private-key "$PRIVATE_KEY" \
      "$@")
    printf '%s\n' "$output" >&2
    address=$(printf '%s\n' "$output" | awk '/Deployed to:/ {print $3}')
    if [ -z "$address" ]; then
      echo "Failed to parse deployed address for $contract" >&2
      return 1
    fi
    code=$(cast code "$address" --rpc-url "$RPC")
    if [ "$code" = "0x" ]; then
      echo "Deployment for $contract reported success but no code was found at $address" >&2
      return 1
    fi
    printf '%s\n' "$address"
  }

  COLLATERAL="$COLLATERAL_TOKEN_ADDRESS"

  PREDICTION_MARKET=$(deploy_contract src/PredictionMarket.sol:PredictionMarket "$PM_GAS_LIMIT")
  cast send "$PREDICTION_MARKET" "initialize(address)" "$COLLATERAL" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
  cast send "$PREDICTION_MARKET" "grantRoles(address,uint256)" "$DEPLOYER" 1 --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
  cast send "$PREDICTION_MARKET" "setMarketCreationFee(uint256)" "$MARKET_CREATION_FEE" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null

  VAULT=$(deploy_contract src/Vault.sol:Vault "$VAULT_GAS_LIMIT" \
    --constructor-args \
    "$PREDICTION_MARKET" \
    "$DEPLOYER" \
    "$FEE_SOURCE" \
    "$DEPLOYER" \
    "$DEFAULT_LAUNCH_THRESHOLD" \
    "$DEFAULT_DEADLINE_DURATION" \
    "$DEPLOYER")

  cast send "$PREDICTION_MARKET" "grantMarketCreatorRole(address)" "$VAULT" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
  cast send "$PREDICTION_MARKET" "grantEscrowManagerRole(address)" "$VAULT" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null

  REWARD_DISTRIBUTOR=$(deploy_contract src/RewardDistributor.sol:RewardDistributor "$RD_GAS_LIMIT" \
    --constructor-args \
    "$COLLATERAL" \
    "$DEPLOYER")

  cat > "$ARTIFACT" <<EOF
{"PredictionMarket":"$PREDICTION_MARKET","Vault":"$VAULT","TestUSDC":"$COLLATERAL","CollateralToken":"$COLLATERAL","RewardDistributor":"$REWARD_DISTRIBUTOR","chainId":$CHAIN_ID,"deployer":"$DEPLOYER","oracle":"$DEPLOYER","surplusRecipient":"$DEPLOYER"}
EOF
else
  forge script "$SCRIPT" \
    --rpc-url "$RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast
fi

if [ ! -f "$ARTIFACT" ]; then
  echo "Missing deployment artifact: $ARTIFACT" >&2
  exit 1
fi

VAULT=$(python3 - <<PY
import json
with open("$ARTIFACT") as f:
    print(json.load(f)["Vault"])
PY
)

COLLATERAL=$(python3 - <<PY
import json
with open("$ARTIFACT") as f:
    data = json.load(f)
    print(data.get("CollateralToken") or data["TestUSDC"])
PY
)

echo ""
echo "--- Post-deploy setup ---"
echo "Vault: $VAULT"
echo "Collateral: $COLLATERAL"

if [ -n "${COLLATERAL_TOKEN_ADDRESS:-}" ]; then
  BALANCE=$(cast call "$COLLATERAL" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC")
  echo "Deployer collateral balance: $BALANCE"

  cast send "$COLLATERAL" \
    "approve(address,uint256)(bool)" \
    "$VAULT" \
    "$INITIAL_FEE_SOURCE_FUNDS" \
    --rpc-url "$RPC" \
    --private-key "$PRIVATE_KEY" >/dev/null

  ALLOWANCE=$(cast call "$COLLATERAL" "allowance(address,address)(uint256)" "$DEPLOYER" "$VAULT" --rpc-url "$RPC")
  echo "Vault allowance: $ALLOWANCE"
fi

if [ "$OPEN_YEAR" != "0" ]; then
  cast send "$VAULT" \
    "openYear(uint16)" \
    "$OPEN_YEAR" \
    --rpc-url "$RPC" \
    --private-key "$PRIVATE_KEY" >/dev/null
  echo "Opened year: $OPEN_YEAR"
fi

echo ""
echo "--- Deployment artifact ---"
cat "$ARTIFACT"
