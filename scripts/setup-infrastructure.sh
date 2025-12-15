#!/bin/bash
# Infrastructure Setup Script
# Sets up EC2 instance with Nitro Enclave support

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

# Get config from state or defaults
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")
INSTANCE_TYPE=$(state_get "instance_type" 2>/dev/null || echo "m5.xlarge")
KEY_NAME=$(state_get "key_name" 2>/dev/null || echo "nitro-enclave-key")
VOLUME_SIZE=$(state_get "volume_size" 2>/dev/null || echo "30")
SG_NAME="nitro-enclave-sg"
INSTANCE_NAME="nitro-enclave-poc"

log_info "Region: $AWS_REGION"
log_info "Instance type: $INSTANCE_TYPE"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found"
    exit 1
fi

# Get latest Amazon Linux 2023 AMI
log_info "Getting latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ssm get-parameters \
    --region "$AWS_REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' \
    --output text)
state_set "ami_id" "$AMI_ID"
log_info "AMI ID: $AMI_ID"

# Check/create key pair
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"

# Check if key exists in AWS (check exit code only)
if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" &>/dev/null; then
    AWS_KEY_EXISTS="yes"
else
    AWS_KEY_EXISTS="no"
fi

if [[ "$AWS_KEY_EXISTS" == "yes" ]] && [[ -f "$KEY_PATH" ]]; then
    log_warn "Key pair '$KEY_NAME' already exists (AWS + local)"
elif [[ "$AWS_KEY_EXISTS" == "yes" ]] && [[ ! -f "$KEY_PATH" ]]; then
    log_error "Key '$KEY_NAME' exists in AWS but not locally at $KEY_PATH"
    log_error "Either delete the AWS key pair or restore the local .pem file"
    exit 1
else
    log_info "Creating key pair..."
    mkdir -p ~/.ssh
    
    # Remove existing file if present (with proper permissions)
    if [[ -f "$KEY_PATH" ]]; then
        chmod 600 "$KEY_PATH" 2>/dev/null || true
        rm -f "$KEY_PATH"
    fi
    
    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "$KEY_PATH"
    chmod 400 "$KEY_PATH"
    log_info "Key saved: $KEY_PATH"
fi

# Check/create security group
SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
    log_warn "Security group exists: $SG_ID"
else
    log_info "Creating security group..."
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "Security group for Nitro Enclave POC" \
        --query 'GroupId' \
        --output text)
    
    MY_IP=$(curl -s https://checkip.amazonaws.com)
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "${MY_IP}/32"
    log_info "Security group: $SG_ID (SSH from $MY_IP)"
fi
state_set "sg_id" "$SG_ID"

# Check for existing instance with same name (singleton pattern)
log_info "Checking for existing instance '$INSTANCE_NAME'..."
EXISTING_INSTANCE=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_INSTANCE" != "None" ]] && [[ -n "$EXISTING_INSTANCE" ]]; then
    log_warn "Found existing instance: $EXISTING_INSTANCE"
    
    # Get instance state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$EXISTING_INSTANCE" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    if [[ "$INSTANCE_STATE" == "stopped" ]]; then
        log_info "Instance is stopped, starting it..."
        aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$EXISTING_INSTANCE"
        aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$EXISTING_INSTANCE"
    fi
    
    INSTANCE_ID=$EXISTING_INSTANCE
    log_info "Reusing instance: $INSTANCE_ID"
else
    # Launch new instance
    log_info "No existing instance found. Launching new EC2 instance..."
    # Check if instance profile exists (created in Step 2)
    PROFILE_EXISTS=$(aws iam get-instance-profile --instance-profile-name EnclaveInstanceProfile 2>/dev/null && echo "true" || echo "false")
    
    if [[ "$PROFILE_EXISTS" == "true" ]]; then
        log_info "Launching with instance profile..."
        INSTANCE_ID=$(aws ec2 run-instances \
            --region "$AWS_REGION" \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --security-group-ids "$SG_ID" \
            --iam-instance-profile Name=EnclaveInstanceProfile \
            --enclave-options 'Enabled=true' \
            --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
            --query 'Instances[0].InstanceId' \
            --output text)
    else
        log_info "Instance profile will be attached after Step 2"
        INSTANCE_ID=$(aws ec2 run-instances \
            --region "$AWS_REGION" \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --security-group-ids "$SG_ID" \
            --enclave-options 'Enabled=true' \
            --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
            --query 'Instances[0].InstanceId' \
            --output text)
    fi
    
    log_info "Created instance: $INSTANCE_ID"
    
    # Wait for running
    log_info "Waiting for instance..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
fi

state_set "instance_id" "$INSTANCE_ID" --encrypt

# Get IP
INSTANCE_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
state_set "instance_ip" "$INSTANCE_IP"

echo ""
echo "=========================================="
echo "Instance ID: $INSTANCE_ID"
echo "Public IP:   $INSTANCE_IP"
echo "=========================================="
echo ""
echo "Connect with:"
echo "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${INSTANCE_IP}"
echo ""

log_info "Infrastructure setup complete"
