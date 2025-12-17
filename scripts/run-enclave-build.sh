#!/bin/bash
# Build Enclave via SSM
# Clones repo, builds enclave, and captures PCR0

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
REPO_URL="https://github.com/0xktn/oram-maw-poc.git"

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found"
    exit 1
fi

# Clone repo and build enclave
log_info "Cloning repo and building enclave on EC2..."

COMMANDS='[
    "export HOME=/root",
    "cd /home/ec2-user",
    "rm -rf oram-maw-poc",
    "git clone '"$REPO_URL"'",
    "cd oram-maw-poc",
    "chmod +x scripts/*.sh",
    "export NITRO_CLI_ARTIFACTS=/home/ec2-user/oram-maw-poc/build",
    "mkdir -p build",
    "docker build -t confidential-enclave:latest -f enclave/Dockerfile . 2>&1",
    "nitro-cli build-enclave --docker-uri confidential-enclave:latest --output-file /home/ec2-user/oram-maw-poc/build/enclave.eif 2>&1 | tee /tmp/enclave-build.log",
    "tail -n 500 /tmp/enclave-build.log"
]'

COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=$COMMANDS" \
    --timeout-seconds 900 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"
log_info "Building enclave (this takes 5-10 minutes)..."

# Wait for command to complete
while true; do
    STATUS=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")
    
    case "$STATUS" in
        "Success")
            echo ""
            log_info "Enclave build completed!"
            break
            ;;
        "Failed"|"Cancelled"|"TimedOut")
            log_error "Enclave build failed: $STATUS"
            aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' \
                --output text
            exit 1
            ;;
        *)
            echo -n "."
            sleep 15
            ;;
    esac
done

# Get build output and extract PCR0
log_info "Extracting PCR0 from build output..."

OUTPUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

# Extract PCR0 value (compatible with Amazon Linux grep - no -P flag)
PCR0=$(echo "$OUTPUT" | grep -o '"PCR0": "[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [[ -z "$PCR0" ]]; then
    # Try alternative: look for 96-char hex string after PCR0
    PCR0=$(echo "$OUTPUT" | grep "PCR0" | grep -oE '[a-f0-9]{96}' | head -1 || echo "")
fi

if [[ -z "$PCR0" ]]; then
    log_error "Could not extract PCR0 from build output"
    echo "Build output:"
    echo "$OUTPUT"
    exit 1
fi

log_info "PCR0: $PCR0"
state_set "pcr0" "$PCR0" --encrypt
state_complete "enclave_built"

echo ""
echo "Enclave built successfully!"
echo "PCR0: $PCR0"
echo ""
