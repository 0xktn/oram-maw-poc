#!/bin/bash
# Run Enclave via SSM
# Starts the enclave as a background process

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INSTANCE_ID=$(state_get "instance_id" 2>/dev/null || echo "")
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found"
    exit 1
fi

log_info "Starting enclave on EC2..."

# Read configuration from state
ENCLAVE_MEM=$(state_get "enclave_memory_mb" 2>/dev/null || echo "2048")
ENCLAVE_CPU=$(state_get "enclave_cpu_count" 2>/dev/null || echo "2")

log_info "Enclave config: ${ENCLAVE_CPU} CPUs, ${ENCLAVE_MEM} MB memory"

# Run enclave with correct path - includes vsock-proxy setup
COMMANDS="[
    \"export HOME=/root\",
    \"cd /home/ec2-user/oram-maw-poc\",
    \"export NITRO_CLI_ARTIFACTS=/home/ec2-user/oram-maw-poc/build\",
    \"echo 'Stopping existing vsock-proxy...'\",
    \"pkill vsock-proxy || true\",
    \"echo 'Starting vsock-proxy for KMS...' \",
    \"nohup vsock-proxy 8000 kms.${AWS_REGION}.amazonaws.com 443 > /tmp/vsock-proxy.log 2>&1 &\",
    \"sleep 2\",
    \"pgrep vsock-proxy && echo 'vsock-proxy running' || { echo '[ERROR] vsock-proxy failed'; exit 1; }\",
    \"nitro-cli run-enclave --cpu-count ${ENCLAVE_CPU} --memory ${ENCLAVE_MEM} --eif-path /home/ec2-user/oram-maw-poc/build/enclave.eif --enclave-cid 16 2>&1 || echo ENCLAVE_FAILED\",
    \"sleep 3\",
    \"nitro-cli describe-enclaves\"
]"

COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=$COMMANDS" \
    --timeout-seconds 120 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"

# Wait for command
sleep 15

STATUS=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' \
    --output text 2>/dev/null || echo "Pending")

if [[ "$STATUS" == "Success" ]]; then
    OUTPUT=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text)
    
    if echo "$OUTPUT" | grep -q "EnclaveID"; then
        ENCLAVE_ID=$(echo "$OUTPUT" | grep -o '"EnclaveID": "[^"]*"' | cut -d'"' -f4)
        log_info "Enclave running: $ENCLAVE_ID"
        state_set "enclave_id" "$ENCLAVE_ID"
        state_complete "enclave_running"
    else
        log_error "Enclave failed to start. Output:"
        echo "$OUTPUT"
        exit 1
    fi
else
    log_error "Command status: $STATUS"
    exit 1
fi
