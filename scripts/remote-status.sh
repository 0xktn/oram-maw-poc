#!/bin/bash
# Remote Status Check Script
# Queries EC2 instance state via AWS SSM Run Command

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

# Get instance ID from state
INSTANCE_ID=$(state_get "instance_id" 2>/dev/null || echo "")
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found in state. Run setup first."
    exit 1
fi

log_info "Checking remote state for instance: $INSTANCE_ID"

# Check if instance is running
INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")

if [[ "$INSTANCE_STATE" != "running" ]]; then
    log_warn "Instance state: $INSTANCE_STATE (not running)"
    echo ""
    echo "Remote Status:"
    echo "  Instance: $INSTANCE_STATE"
    exit 0
fi

# Check SSM connectivity
SSM_STATUS=$(aws ssm describe-instance-information \
    --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "Unknown")

if [[ "$SSM_STATUS" != "Online" ]]; then
    log_warn "SSM Agent not online. Status: $SSM_STATUS"
    log_warn "Instance may need IAM role attached or time to initialize."
    echo ""
    echo "Remote Status:"
    echo "  Instance: running"
    echo "  SSM: $SSM_STATUS"
    exit 0
fi

log_info "SSM Agent online, querying instance..."

# Run status check command via SSM
COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "echo NITRO_CLI=$(command -v nitro-cli >/dev/null 2>&1 && echo installed || echo missing)",
        "echo DOCKER=$(command -v docker >/dev/null 2>&1 && echo installed || echo missing)",
        "echo ENCLAVE_EIF=$(ls -1 *.eif 2>/dev/null | head -1 || echo missing)",
        "echo ENCLAVE_RUNNING=$(nitro-cli describe-enclaves 2>/dev/null | grep -q EnclaveID && echo yes || echo no)"
    ]' \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

if [[ -z "$COMMAND_ID" ]]; then
    log_error "Failed to send SSM command"
    exit 1
fi

# Wait for command to complete
log_info "Waiting for response..."
sleep 3

# Get command output
OUTPUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

# Parse output
NITRO_CLI=$(echo "$OUTPUT" | grep "NITRO_CLI=" | cut -d'=' -f2)
DOCKER=$(echo "$OUTPUT" | grep "DOCKER=" | cut -d'=' -f2)
ENCLAVE_EIF=$(echo "$OUTPUT" | grep "ENCLAVE_EIF=" | cut -d'=' -f2)
ENCLAVE_RUNNING=$(echo "$OUTPUT" | grep "ENCLAVE_RUNNING=" | cut -d'=' -f2)

# Save to state
[[ "$NITRO_CLI" == "installed" ]] && state_complete "remote_nitro_cli" || true
[[ "$DOCKER" == "installed" ]] && state_complete "remote_docker" || true
[[ "$ENCLAVE_EIF" != "missing" ]] && state_set "remote_enclave_eif" "$ENCLAVE_EIF" && state_complete "remote_enclave_built" || true
[[ "$ENCLAVE_RUNNING" == "yes" ]] && state_complete "remote_enclave_running" || true

# Display results
echo ""
echo "Remote Status (EC2: $INSTANCE_ID):"
[[ "$NITRO_CLI" == "installed" ]] && echo "  ✓ Nitro CLI installed" || echo "  ○ Nitro CLI not installed"
[[ "$DOCKER" == "installed" ]] && echo "  ✓ Docker installed" || echo "  ○ Docker not installed"
[[ "$ENCLAVE_EIF" != "missing" ]] && echo "  ✓ Enclave built ($ENCLAVE_EIF)" || echo "  ○ Enclave not built"
[[ "$ENCLAVE_RUNNING" == "yes" ]] && echo "  ✓ Enclave running" || echo "  ○ Enclave not running"
echo ""
