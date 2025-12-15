#!/bin/bash
# Cleanup Script - Delete all AWS resources
# This terminates EC2, deletes IAM roles, KMS keys, security groups, and key pairs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")
INSTANCE_NAME="nitro-enclave-poc"
KEY_NAME="nitro-enclave-key"
SG_NAME="nitro-enclave-sg"
ROLE_NAME="EnclaveInstanceRole"
PROFILE_NAME="EnclaveInstanceProfile"

echo ""
echo "========================================"
echo "  Cleaning up ALL AWS resources"
echo "========================================"
echo ""

# 1. Stop remote processes before terminating (if instance exists)
INSTANCE_ID=$(state_get "instance_id" 2>/dev/null || echo "")
if [[ -n "$INSTANCE_ID" ]]; then
    log_info "Stopping remote processes on $INSTANCE_ID..."
    aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["nitro-cli terminate-enclave --all || true", "pkill vsock-proxy || true", "pkill -f host/worker.py || true", "docker compose -f /home/ec2-user/temporal-docker/docker-compose.yml down 2>/dev/null || true"]' \
        2>/dev/null || true
    sleep 5
    log_info "Remote processes stopped"
fi

# 2. Terminate EC2 instances with matching name
log_info "Finding EC2 instances named '$INSTANCE_NAME'..."
INSTANCES=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$INSTANCES" ]]; then
    log_warn "Terminating instances: $INSTANCES"
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $INSTANCES >/dev/null
    log_info "Waiting for termination..."
    aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $INSTANCES 2>/dev/null || true
    log_info "Instances terminated"
else
    log_info "No matching instances found"
fi

# 3. Delete IAM instance profile
log_info "Deleting IAM instance profile..."
aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile \
    --instance-profile-name "$PROFILE_NAME" 2>/dev/null || true
log_info "Instance profile deleted"

# 4. Delete IAM role and policies
log_info "Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name KMSDecryptPolicy 2>/dev/null || true
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
log_info "IAM role deleted"

# 5. Delete KMS key
log_info "Deleting KMS key..."
KMS_KEY_ID=$(state_get "kms_key_id" 2>/dev/null || echo "")
KMS_ALIAS="alias/confidential-workflow-tsk"

if [[ -n "$KMS_KEY_ID" ]]; then
    # Delete alias first
    aws kms delete-alias --region "$AWS_REGION" --alias-name "$KMS_ALIAS" 2>/dev/null || true
    
    # Schedule key for deletion (minimum 7 days)
    aws kms schedule-key-deletion \
        --region "$AWS_REGION" \
        --key-id "$KMS_KEY_ID" \
        --pending-window-in-days 7 2>/dev/null || true
    log_info "KMS key scheduled for deletion (7 days)"
else
    log_info "No KMS key found in state"
fi

# 6. Delete security group
log_info "Deleting security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")
if [[ "$SG_ID" != "None" ]] && [[ -n "$SG_ID" ]]; then
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" 2>/dev/null || true
    log_info "Security group deleted: $SG_ID"
else
    log_info "No security group found"
fi

# 6. Delete key pair
log_info "Deleting key pair..."
aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$KEY_NAME" 2>/dev/null || true
if [[ -f "$HOME/.ssh/${KEY_NAME}.pem" ]]; then
    rm -f "$HOME/.ssh/${KEY_NAME}.pem" 2>/dev/null || true
    log_info "Deleted local key file"
fi
log_info "Key pair deleted"

# 7. Reset local state
log_info "Resetting local state..."
state_reset

# 8. Clean up local files
rm -f encrypted-tsk.b64 2>/dev/null || true
rm -rf temporal-docker 2>/dev/null || true
rm -rf config 2>/dev/null || true

echo ""
echo "========================================"
echo "  Cleanup Complete!"
echo "========================================"
echo ""
echo "All AWS resources have been deleted."
echo "NOTE: KMS key is scheduled for deletion in 7 days (AWS minimum)"
echo "Run './scripts/setup.sh' to start fresh."
echo ""
