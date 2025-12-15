#!/bin/bash
# Apply KMS Key Policy with PCR0 Attestation
# Usage: ./setup-kms-policy.sh <PCR0_VALUE>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

if [ -z "$1" ]; then
    echo "Usage: $0 <PCR0_VALUE>"
    echo ""
    echo "Get PCR0 from: nitro-cli build-enclave output"
    exit 1
fi

PCR0="$1"
state_set "pcr0" "$PCR0" --encrypt

# Get values from state
# Get values from state
AWS_REGION=$(state_get "aws_region" || echo "ap-southeast-1")
AWS_ACCOUNT_ID=$(state_get "aws_account_id" || aws sts get-caller-identity --query Account --output text)
KEY_ID=$(state_get "kms_key_id" || echo "901ee892-db48-4a51-903a-25d46a721c8e")
ROLE_NAME=$(state_get "iam_role_name" || echo "EnclaveInstanceRole")

echo "Applying attestation policy..."
echo "PCR0: $PCR0"

cat > /tmp/kms-key-policy.json << EOF
{
  "Version": "2012-10-17",
  "Id": "confidential-workflow-key-policy",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root"},
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow Enclave Decrypt",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"},
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEqualsIgnoreCase": {
          "kms:RecipientAttestation:ImageSha384": "${PCR0}"
        }
      }
    }
  ]
}
EOF

aws kms put-key-policy \
    --region "$AWS_REGION" \
    --key-id "$KEY_ID" \
    --policy-name default \
    --policy file:///tmp/kms-key-policy.json

rm /tmp/kms-key-policy.json

state_complete "kms_policy"

echo ""
echo "Attestation policy applied!"
echo "Only enclaves with PCR0=$PCR0 can decrypt."
