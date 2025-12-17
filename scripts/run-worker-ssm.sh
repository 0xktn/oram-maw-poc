#!/bin/bash
# Start Host Worker via SSM
# Starts the Temporal worker as a background process

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
TEMPORAL_HOST=$(state_get "temporal_host" 2>/dev/null || echo "localhost:7233")

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found"
    exit 1
fi

log_info "Starting host worker on EC2..."

# Install Python and run worker
COMMANDS='[
    "sudo dnf install -y python3 python3-pip 2>&1 || echo pip already installed",
    "cd /home/ec2-user/oram-maw-poc/host",
    "python3 -m pip install -r requirements.txt --user 2>&1 || true",
    "export TEMPORAL_HOST='"$TEMPORAL_HOST"'",
    "nohup python3 worker.py > /tmp/worker.log 2>&1 &",
    "sleep 3",
    "pgrep -f worker.py && echo Worker started || echo Worker not found"
]'

COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=$COMMANDS" \
    --timeout-seconds 180 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"

# Wait for command
sleep 20

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
    
    if echo "$OUTPUT" | grep -q "Worker started"; then
        log_info "Host worker running!"
        state_complete "worker_running"
    else
        log_error "Worker failed to start. Output:"
        echo "$OUTPUT"
        exit 1
    fi
else
    log_error "Command status: $STATUS"
    exit 1
fi
