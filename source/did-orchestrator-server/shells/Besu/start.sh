#!/bin/bash
set -euo pipefail

SERVER_IP=${1:-}
CONTRACT_DIR="did-besu-contract"
MAKE_ACCOUNT_WITH_REGIST_ROLE_SCRIPT="$CONTRACT_DIR/scripts/deploy-and-make-account-with-regist-role.js"
TAR_FILE="did-besu-contract-2.0.0.tar.gz"
OUTPUT_FILE="besu.dat"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ENV_FILE="${ENV_FILE:-.env}"
CONTAINER="${CONTAINER:-opendid-besu-node}"

MIN_PEERS="${MIN_PEERS:-5}"
PEER_TIMEOUT="${PEER_TIMEOUT:-180}"
BLOCK_TIMEOUT="${BLOCK_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"

rpc_call() {
  local method="$1"; local params="${2:-[]}"
  curl -s --max-time 3 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
    "$RPC_URL"
}

have_jq() { command -v jq >/dev/null 2>&1; }

hex2dec() {
  local h="${1#0x}"
  printf "%d" "0x$h"
}

get_block_number() {
  local raw bn
  raw="$(rpc_call eth_blockNumber)"
  if have_jq; then
    bn="$(printf '%s' "$raw" | jq -r '.result // "0x0"')"
  else
    bn="$(printf '%s' "$raw" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\(0x[0-9a-fA-F]\+\)".*/\1/p')"
    [ -z "$bn" ] && bn="0x0"
  fi
  hex2dec "$bn"
}

wait_rpc_ready() {
  echo "Waiting for RPC to respond..."
  for _ in $(seq 1 60); do
    if rpc_call net_version | grep -q '"result"'; then return 0; fi
    sleep 2
  done
  echo "RPC not responding in time." >&2
  return 1
}

wait_peers() {
  local min="$1" timeout="$2" elapsed=0
  echo "Waiting for peers >= $min (timeout ${timeout}s)..."
  while (( elapsed < timeout )); do
    local pc_hex pc
    if have_jq; then
      pc_hex="$(rpc_call net_peerCount | jq -r '.result // "0x0"')"
    else
      pc_hex="$(rpc_call net_peerCount | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\(0x[0-9a-fA-F]\+\)".*/\1/p')"
      [ -z "$pc_hex" ] && pc_hex="0x0"
    fi
    pc=$(hex2dec "$pc_hex")
    printf "\rPeers: %d" "$pc"
    if (( pc >= min )); then echo; return 0; fi
    sleep "$POLL_INTERVAL"; elapsed=$((elapsed+POLL_INTERVAL))
  done
  echo
  echo "Peers did not reach $min within ${timeout}s." >&2
  return 1
}

wait_block_production() {
  local timeout="$1" elapsed=0
  local start_bn next_bn
  start_bn="$(get_block_number)"
  echo "Waiting for block production (start height: $start_bn, timeout ${timeout}s)..."
  while (( elapsed < timeout )); do
    next_bn="$(get_block_number)"
    printf "\rBlockNumber: %d" "$next_bn"
    if (( next_bn > start_bn )); then
      echo
      echo "Block production detected (height advanced from $start_bn to $next_bn)."
      return 0
    fi
    sleep "$POLL_INTERVAL"; elapsed=$((elapsed+POLL_INTERVAL))
  done
  echo
  echo "No new blocks produced within ${timeout}s." >&2
  return 1
}

# 1) 컨트랙트 파일 준비
if [ ! -f "$MAKE_ACCOUNT_WITH_REGIST_ROLE_SCRIPT" ]; then
  echo "Contract files are compressed."
  if [ -f "$TAR_FILE" ]; then
    echo "Extracting $TAR_FILE..."
    tar -xvf "$TAR_FILE"
  else
    echo "Cannot find compressed file $TAR_FILE. Exiting."
    exit 1
  fi
else
  echo "Contract files are ready."
fi
find "./$CONTRACT_DIR/contracts/" -name "*.sol" -exec sed -i '/Mac OS X/d' {} \; 2>/dev/null

# 2) RPC(부트노드)만 먼저 기동
if command -v docker-compose &> /dev/null; then
  echo "Using docker-compose..."; docker-compose up -d rpc
elif docker compose version &> /dev/null; then
  echo "Using docker compose..."; docker compose up -d rpc
else
  echo "Neither docker-compose nor docker compose found!"; exit 1
fi

echo "Besu container started. Waiting a bit..."
sleep 3
wait_rpc_ready

# 3) BOOT_NODE_ID 추출 후 .env 반영
RAW="$(rpc_call admin_nodeInfo)"
if have_jq; then
  BOOT_ID="$(printf '%s' "$RAW" | jq -r '.result.id // empty')"
  [ -z "$BOOT_ID" ] && BOOT_ID="$(printf '%s' "$RAW" \
    | jq -r '.result.enode' | sed -n 's#^enode://\([0-9a-fA-F]\+\)@.*#\1#p')"
else
  BOOT_ID="$(printf '%s' "$RAW" \
    | sed -n 's#.*"id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{128\}\)".*#\1#p')"
  [ -z "$BOOT_ID" ] && BOOT_ID="$(printf '%s' "$RAW" \
    | sed -n 's#.*enode://\([0-9a-fA-F]\+\)@.*#\1#p')"
fi
if ! echo "${BOOT_ID:-}" | grep -qiE '^[0-9a-f]{128}$'; then
  echo "Failed to parse boot node id. admin_nodeInfo not ready yet." >&2
  echo "Raw admin_nodeInfo: $RAW" >&2
  exit 2
fi

touch "$ENV_FILE"
if grep -q '^BOOT_NODE_ID=' "$ENV_FILE"; then
  sed -i.bak "s/^BOOT_NODE_ID=.*/BOOT_NODE_ID=$BOOT_ID/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
  echo "BOOT_NODE_ID=$BOOT_ID" >> "$ENV_FILE"
fi
echo "BOOT_NODE_ID set to $BOOT_ID in $ENV_FILE"

# 4) 전체 노드 기동
if command -v docker-compose &> /dev/null; then
  echo "Using docker-compose..."; docker-compose up -d
else
  echo "Using docker compose..."; docker compose up -d
fi

# 5) **피어 연결 정상 확인**
wait_peers "$MIN_PEERS" "$PEER_TIMEOUT"

# 6) **블록 생성 시작 확인**
wait_block_production "$BLOCK_TIMEOUT"

# 7) Hardhat 프로젝트 확인 및 설치
cd "$CONTRACT_DIR" || { echo "Failed to move to $CONTRACT_DIR"; exit 1; }
if [ ! -f "hardhat.config.js" ]; then
  echo "hardhat.config.js not found. This is not a valid Hardhat project."; exit 1
fi
if [ ! -f "node_modules/.bin/hardhat" ]; then
  echo "Hardhat is not installed locally. Installing..."
  npm cache clean --force
  npm install --save-dev hardhat
else
  echo "Hardhat is already installed locally."
fi

# 8) 기존 배포 상태 체크
STATUS_SCRIPT_PATH="$(pwd)/../status.sh"
ACCOUNT_INFO_PATH="$(pwd)/../$OUTPUT_FILE"
if [ ! -f "$STATUS_SCRIPT_PATH" ]; then
  echo "status.sh not found: $STATUS_SCRIPT_PATH"; exit 1
fi

echo "Checking contract deployment status..."
bash "$STATUS_SCRIPT_PATH" "$ACCOUNT_INFO_PATH"
if [ $? -eq 200 ]; then
  echo "starting checked"  # 이미 배포되어 있음
else
  echo "Contract deployment required. Starting new deployment..."
  echo "Hardhat: Deploying contracts and creating accounts with roles..."
  DEPLOY_OUTPUT=$(npx hardhat run scripts/deploy-and-make-account-with-regist-role.js --network dev)
  echo "$DEPLOY_OUTPUT"
  echo "$DEPLOY_OUTPUT" > "$ACCOUNT_INFO_PATH"
  echo "Chaincode initialization is not required."
fi

cd ..

# 9) 배포 결과 파싱
CONTRACT_ADDRESS=$(grep "OpenDID deployed to:" "$ACCOUNT_INFO_PATH" | cut -d ':' -f2- | xargs)
DEPLOYER_ADDRESS=$(grep "Deploying the contract with the account:" "$ACCOUNT_INFO_PATH" | cut -d ':' -f2- | xargs)
TAS_ADDRESS=$(grep "== TAS Ethereum Wallet ==" -A 2 "$ACCOUNT_INFO_PATH" | grep "Address:" | cut -d ':' -f2- | xargs)
TAS_PRIVATE_KEY=$(grep "Private Key TAS:" "$ACCOUNT_INFO_PATH" | cut -d ':' -f2- | xargs)
ISSUER_ADDRESS=$(grep "== Issuer Ethereum Wallet ==" -A 2 "$ACCOUNT_INFO_PATH" | grep "Address:" | cut -d ':' -f2- | xargs)
ISSUER_PRIVATE_KEY=$(grep "Private Key Issuer:" "$ACCOUNT_INFO_PATH" | cut -d ':' -f2- | xargs)

echo "Extracted information:"
echo "Contract Address: $CONTRACT_ADDRESS"
echo "Deployer Address: $DEPLOYER_ADDRESS"
echo "TAS Address: $TAS_ADDRESS"
echo "TAS Private Key: $TAS_PRIVATE_KEY"
echo "Issuer Address: $ISSUER_ADDRESS"
echo "Issuer Private Key: $ISSUER_PRIVATE_KEY"

# 10) 검증
[ -z "$CONTRACT_ADDRESS" ] && { echo "Failed to extract contract address"; exit 1; }
[ -z "$TAS_PRIVATE_KEY" ] || [ -z "$ISSUER_PRIVATE_KEY" ] && { echo "Failed to extract TAS or Issuer private keys"; exit 1; }

# 11) blockchain.properties 생성
generate_blockchain_properties() {
  local target_path="$1"; local include_private_key="$2"; local private_key="${3:-}"
  local target_dir; target_dir="$(dirname "$target_path")"
  [ -d "$target_dir" ] || { echo "Creating directory: $target_dir"; mkdir -p "$target_dir"; }
  echo "Generating blockchain.properties at: $target_path"
  {
    echo "evm.network.url=http://localhost:8545"
    echo "evm.chainId=1337"
    echo "evm.gas.limit=10000000"
    echo "evm.gas.price=0"
    echo "evm.connection.timeout=10000"
    echo "evm.contract.address=${CONTRACT_ADDRESS}"
    if [ "$include_private_key" = true ]; then
      echo "evm.contract.privateKey=${private_key}"
    fi
  } > "$target_path"
}

COMMON_BLOCKCHAIN="${PWD}/blockchain.properties"
generate_blockchain_properties "$COMMON_BLOCKCHAIN" false ""

TA_BLOCKCHAIN_PATH="${PWD}/TA/blockchain.properties"
generate_blockchain_properties "$TA_BLOCKCHAIN_PATH" true "$TAS_PRIVATE_KEY"

ISSUER_BLOCKCHAIN_PATH="${PWD}/Issuer/blockchain.properties"
generate_blockchain_properties "$ISSUER_BLOCKCHAIN_PATH" true "$ISSUER_PRIVATE_KEY"

echo "blockchain.properties files generated successfully:"
echo "- Common: $COMMON_BLOCKCHAIN"
echo "- TAS: $TA_BLOCKCHAIN_PATH"
echo "- Issuer: $ISSUER_BLOCKCHAIN_PATH"

# 12) easy-adoption injector
bash easy-adoption-injector.sh "$SERVER_IP"