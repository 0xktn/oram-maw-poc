#!/bin/bash
# Deploy encrypted TSK to remote EC2 instance

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
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
TSK_FILE="$PROJECT_ROOT/encrypted-tsk.b64"

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found in state"
    exit 1
fi

if [[ ! -f "$TSK_FILE" ]]; then
    log_error "encrypted-tsk.b64 not found at $TSK_FILE"
    log_error "Run setup-kms.sh first to generate the TSK"
    exit 1
fi

log_info "Deploying encrypted TSK to EC2 instance $INSTANCE_ID..."

# Read TSK content
TSK_CONTENT=$(cat "$TSK_FILE")

# Deploy via SSM
COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo '$TSK_CONTENT' > /home/ec2-user/oram-maw-poc/encrypted-tsk.b64\",\"chmod 644 /home/ec2-user/oram-maw-poc/encrypted-tsk.b64\",\"ls -la /home/ec2-user/oram-maw-poc/encrypted-tsk.b64\"]" \
    --timeout-seconds 60 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"

# Wait for completion
sleep 5

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
    
    log_info "TSK deployed successfully!"
    echo "$OUTPUT"
else
    log_error "TSK deployment failed with status: $STATUS"
    exit 1
fi
