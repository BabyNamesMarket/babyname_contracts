-include .env

.PHONY: build test coverage gas clean deploy export-abi anvil

# Build
build:
	forge build

clean:
	forge clean

# Test
test:
	forge test -vvv

test-ci:
	FOUNDRY_PROFILE=ci forge test -vvv

coverage:
	forge coverage

gas:
	forge snapshot

# ABI export
export-abi:
	@mkdir -p abi
	forge inspect PredictionMarket abi --json > abi/PredictionMarket.json
	forge inspect Launchpad abi --json > abi/Launchpad.json
	forge inspect OutcomeToken abi --json > abi/OutcomeToken.json
	@echo "ABIs exported to abi/"

# Local dev
anvil:
	anvil

deploy-local:
	forge script script/DeployTestnet.s.sol:DeployTestnet --rpc-url http://127.0.0.1:8545 --broadcast

# Base Sepolia
deploy-base-sepolia:
	DEPLOY_STAGE=commit bash script/deploy-base-sepolia.sh

deploy-base-sepolia-live:
	DEPLOY_STAGE=live bash script/deploy-base-sepolia.sh

# Tempo testnet (uses shell script due to Tempo gas estimation requirements)
deploy-tempo-testnet:
	bash script/deploy-tempo-testnet.sh
