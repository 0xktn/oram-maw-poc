#!/bin/bash
# Run Instance Setup via SSM
# Executes setup-instance.sh on the remote EC2 via AWS SSM

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
MAX_WAIT=600  # 10 minutes (instance restart + boot + SSM agent)

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found"
    exit 1
fi

# Wait for SSM to be online
log_info "Waiting for SSM agent to come online (max ${MAX_WAIT}s)..."
WAITED=0
LAST_MSG=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    SSM_STATUS=$(aws ssm describe-instance-information \
        --region "$AWS_REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$SSM_STATUS" == "Online" ]]; then
        log_info "SSM agent online!"
        break
    fi
    
    # Progress message every 60 seconds
    if [[ $((WAITED - LAST_MSG)) -ge 60 ]]; then
        log_info "Still waiting... (${WAITED}s elapsed)"
        LAST_MSG=$WAITED
    fi
    
    echo -n "."
    sleep 10
    WAITED=$((WAITED + 10))
done
echo ""

if [[ "$SSM_STATUS" != "Online" ]]; then
    log_error "SSM agent not online after ${MAX_WAIT}s"
    log_error "Try: ssh -i ~/.ssh/$(state_get key_name).pem ec2-user@$(state_get instance_ip)"
    exit 1
fi

# Run instance setup commands via SSM
log_info "Running instance setup via SSM..."

COMMANDS='[
    "sudo dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel docker git python3 python3-pip",
    "sudo systemctl enable --now docker",
    "sudo mkdir -p /usr/local/lib/docker/cli-plugins",
    "sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose",
    "sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose",
    "sudo systemctl enable --now nitro-enclaves-allocator.service",
    "sudo usermod -aG ne ec2-user",
    "sudo usermod -aG docker ec2-user",
    "sudo cp /etc/nitro_enclaves/allocator.yaml /etc/nitro_enclaves/allocator.yaml.bak",
    "echo -e \"---\\nmemory_mib: 2048\\ncpu_count: 2\" | sudo tee /etc/nitro_enclaves/allocator.yaml",
    "sudo systemctl restart nitro-enclaves-allocator.service",
    "nitro-cli --version",
    "docker --version",
    "docker compose version",
    "python3 --version"
]'

COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=$COMMANDS" \
    --timeout-seconds 600 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"
log_info "Waiting for completion (this takes 2-3 minutes)..."

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
            log_info "Instance setup completed!"
            state_complete "instance_setup"
            break
            ;;
        "Failed"|"Cancelled"|"TimedOut")
            log_error "Instance setup failed: $STATUS"
            # Show output
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
            sleep 10
            ;;
    esac
done
echo ""

# Verify
log_info "Verifying installation..."
OUTPUT=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["nitro-cli --version && docker --version"]' \
    --query 'Command.CommandId' \
    --output text)

sleep 5

RESULT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$OUTPUT" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

echo "$RESULT"
log_info "Instance setup complete via SSM!"
