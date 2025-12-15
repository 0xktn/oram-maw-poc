#!/bin/bash
# KMS Setup Script
# Creates KMS key with attestation policy for Nitro Enclaves

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Get config from state
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")
KEY_ALIAS="confidential-workflow-tsk"
ROLE_NAME="EnclaveInstanceRole"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
state_set "aws_account_id" "$AWS_ACCOUNT_ID" --encrypt

log_info "Account: $AWS_ACCOUNT_ID"
log_info "Region: $AWS_REGION"

# Check if key exists
EXISTING_KEY=$(aws kms list-aliases \
    --region "$AWS_REGION" \
    --query "Aliases[?AliasName=='alias/${KEY_ALIAS}'].TargetKeyId" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_KEY" ]; then
    log_warn "KMS key exists: $EXISTING_KEY"
    KEY_ID=$EXISTING_KEY
else
    log_info "Creating KMS key..."
    KEY_ID=$(aws kms create-key \
        --region "$AWS_REGION" \
        --description "Trusted Session Key for Confidential Multi-Agent Workflow" \
        --key-usage ENCRYPT_DECRYPT \
        --key-spec SYMMETRIC_DEFAULT \
        --query 'KeyMetadata.KeyId' \
        --output text)
    
    aws kms create-alias \
        --region "$AWS_REGION" \
        --alias-name "alias/${KEY_ALIAS}" \
        --target-key-id "$KEY_ID"
    log_info "Created KMS key: $KEY_ID"
fi
state_set "kms_key_id" "$KEY_ID" --encrypt
state_set "kms_key_alias" "$KEY_ALIAS"

# Create IAM role
log_info "Setting up IAM role..."

cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    log_warn "IAM role exists"
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/ec2-trust-policy.json
    log_info "Created role: $ROLE_NAME"
fi
state_set "iam_role_name" "$ROLE_NAME"

# Create KMS policy
cat > /tmp/kms-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["kms:Decrypt"],
    "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${KEY_ID}"
  }]
}
EOF

aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name KMSDecryptPolicy \
    --policy-document file:///tmp/kms-policy.json
log_info "Attached KMS policy"

# Attach SSM policy for remote state sync
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || log_warn "SSM policy already attached"
log_info "Attached SSM policy"

# Create instance profile
if aws iam get-instance-profile --instance-profile-name EnclaveInstanceProfile &> /dev/null; then
    log_warn "Instance profile exists"
else
    aws iam create-instance-profile --instance-profile-name EnclaveInstanceProfile
    aws iam add-role-to-instance-profile \
        --instance-profile-name EnclaveInstanceProfile \
        --role-name "$ROLE_NAME"
    log_info "Created instance profile"
fi

# Generate encrypted TSK
log_info "Generating encrypted TSK..."
aws kms generate-data-key \
    --region "$AWS_REGION" \
    --key-id "alias/${KEY_ALIAS}" \
    --key-spec AES_256 \
    --output json > /tmp/data-key.json

cat /tmp/data-key.json | jq -r '.CiphertextBlob' > encrypted-tsk.b64
rm /tmp/data-key.json
state_set "encrypted_tsk_path" "encrypted-tsk.b64"

echo ""
echo "=========================================="
echo "KMS Setup Complete!"
echo "Key ID: $KEY_ID"
echo "Role:   $ROLE_NAME"
echo "TSK:    encrypted-tsk.b64"
echo "=========================================="
echo ""
echo "Next: Build enclave to get PCR0, then run:"
echo "  ./scripts/setup-kms-policy.sh <PCR0>"
echo ""

# Cleanup
rm -f /tmp/ec2-trust-policy.json /tmp/kms-policy.json

log_info "KMS setup complete"
