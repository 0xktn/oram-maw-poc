#!/bin/bash
#
# Confidential Multi-Agent Workflow - Main Setup Script
#
# Usage:
#   ./setup.sh [OPTIONS]
#
# Options:
#   -h, --help          Show help
#   -r, --region REGION AWS region (default: ap-southeast-1)
#   -t, --type TYPE     EC2 instance type (default: m5.xlarge)
#   --status            Show current setup status
#   --reset             Reset all state and start fresh
#   --dry-run           Preview without executing
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source state management
source "$SCRIPT_DIR/lib/state.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}▶ $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# Default configuration
DEFAULT_REGION="ap-southeast-1"
DEFAULT_INSTANCE_TYPE="m5.xlarge"
DEFAULT_KEY_NAME="nitro-enclave-key"
DEFAULT_VOLUME_SIZE="30"

DRY_RUN=false
SHOW_STATUS=false
SHOW_REMOTE_STATUS=false
RESET_STATE=false

# Parse arguments
show_help() {
    cat << EOF
Confidential Multi-Agent Workflow - Setup Script

Usage: $0 [OPTIONS]

Options:
    -h, --help              Show this help
    -r, --region REGION     AWS region (default: $DEFAULT_REGION)
    -t, --type TYPE         EC2 instance type (default: $DEFAULT_INSTANCE_TYPE)
    --status                Show current setup status
    --remote-status         Show status including remote EC2 state
    --reset                 Reset local state only
    --clean                 Delete ALL AWS resources and reset
    --dry-run               Preview without executing

Examples:
    $0                      # Run setup (auto-resumes from last step)
    $0 --status             # Check what's done
    $0 --reset              # Start fresh
    $0 --region us-west-2   # Use different region
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -r|--region) state_set "aws_region" "$2"; shift 2 ;;
        -t|--type) state_set "instance_type" "$2"; shift 2 ;;
        --status) SHOW_STATUS=true; shift ;;
        --remote-status) SHOW_REMOTE_STATUS=true; shift ;;
        --reset) RESET_STATE=true; shift ;;
        --clean) CLEAN_ALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# Initialize state
state_init

# Initialize default configuration if not set
if ! state_get "enclave_cpu_count" >/dev/null 2>&1; then
    state_set "enclave_cpu_count" "2"
fi

if ! state_get "enclave_memory_mb" >/dev/null 2>&1; then
    state_set "enclave_memory_mb" "2048"
fi

if ! state_get "debug_mode" >/dev/null 2>&1; then
    state_set "debug_mode" "false"
fi


# Handle --clean (delete all AWS resources)
if [[ "$CLEAN_ALL" == "true" ]]; then
    "$SCRIPT_DIR/cleanup.sh"
    exit 0
fi

# Handle --reset (local state only)
if [[ "$RESET_STATE" == "true" ]]; then
    log_warn "Resetting local state only (use --clean to delete AWS resources)..."
    state_reset
    log_info "State reset complete"
    exit 0
fi

# Handle --status
if [[ "$SHOW_STATUS" == "true" ]]; then
    state_status
    exit 0
fi

# Handle --remote-status
if [[ "$SHOW_REMOTE_STATUS" == "true" ]]; then
    state_status
    "$SCRIPT_DIR/remote-status.sh"
    exit 0
fi

# Load or set defaults
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "$DEFAULT_REGION")
INSTANCE_TYPE=$(state_get "instance_type" 2>/dev/null || echo "$DEFAULT_INSTANCE_TYPE")
KEY_NAME=$(state_get "key_name" 2>/dev/null || echo "$DEFAULT_KEY_NAME")
VOLUME_SIZE=$(state_get "volume_size" 2>/dev/null || echo "$DEFAULT_VOLUME_SIZE")

# Save config to state
state_set "aws_region" "$AWS_REGION"
state_set "instance_type" "$INSTANCE_TYPE"
state_set "key_name" "$KEY_NAME"
state_set "volume_size" "$VOLUME_SIZE"

# Export for child scripts
export AWS_REGION INSTANCE_TYPE KEY_NAME VOLUME_SIZE
export STATE_DIR STATE_DB

# Pre-flight validation
ENCLAVE_MEM=$(state_get "enclave_memory_mb" 2>/dev/null || echo "2048")
ENCLAVE_CPU=$(state_get "enclave_cpu_count" 2>/dev/null || echo "2")
ALLOCATOR_MEM=2048  # Default allocator memory in run-instance-setup.sh

if [[ $ENCLAVE_MEM -gt $ALLOCATOR_MEM ]]; then
    log_warn "Enclave memory ($ENCLAVE_MEM MB) exceeds allocator ($ALLOCATOR_MEM MB)"
    log_warn "Reduce enclave_memory_mb or update /etc/nitro_enclaves/allocator.yaml"
fi

# Display status
echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  Confidential Multi-Agent Workflow Setup   │"
echo "└─────────────────────────────────────────────┘"
echo ""
echo "Configuration:"
echo "  Region:        $AWS_REGION"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Key Name:      $KEY_NAME"
echo ""
echo "Step Status:"
state_check "infra" && echo "  ✓ Infrastructure (completed)" || echo "  ○ Infrastructure (pending)"
state_check "kms" && echo "  ✓ KMS Configuration (completed)" || echo "  ○ KMS Configuration (pending)"
state_check "instance_setup" && echo "  ✓ Instance Setup (completed)" || echo "  ○ Instance Setup (pending)"
state_check "temporal" && echo "  ✓ Temporal Server (completed)" || echo "  ○ Temporal Server (pending)"
state_check "enclave_built" && echo "  ✓ Enclave Built (completed)" || echo "  ○ Enclave Built (pending)"
state_check "kms_policy" && echo "  ✓ KMS Policy (completed)" || echo "  ○ KMS Policy (pending)"
state_check "enclave_running" && echo "  ✓ Enclave Running (completed)" || echo "  ○ Enclave Running (pending)"
state_check "worker_running" && echo "  ✓ Worker Running (completed)" || echo "  ○ Worker Running (pending)"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Dry run mode - no changes will be made"
    exit 0
fi

# Check if all done
if state_check "infra" && state_check "kms" && state_check "temporal" && state_check "instance_setup" && state_check "enclave_built" && state_check "kms_policy" && state_check "enclave_running" && state_check "worker_running"; then
    log_info "All 8 steps already completed! Use --reset to start over."
    exit 0
fi

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Check prerequisites
log_step "Checking prerequisites"

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Please install it first."
    exit 1
fi
log_info "AWS CLI: $(aws --version | head -1)"

if ! command -v sqlite3 &> /dev/null; then
    log_error "sqlite3 not found. Please install it first."
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run 'aws configure' first."
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
state_set "aws_account_id" "$AWS_ACCOUNT_ID" --encrypt
log_info "AWS Account: $AWS_ACCOUNT_ID"

# Step 1: Infrastructure
if ! state_check "infra"; then
    log_step "Step 1: Setting up EC2 Infrastructure"
    state_start "infra"
    
    if "$SCRIPT_DIR/setup-infrastructure.sh"; then
        state_complete "infra"
    else
        state_fail "infra"
        log_error "Infrastructure setup failed"
        exit 1
    fi
else
    log_step "Step 1: Infrastructure (Already Complete)"
fi

# Step 2: KMS
if ! state_check "kms"; then
    log_step "Step 2: Setting up AWS KMS"
    state_start "kms"
    
    if "$SCRIPT_DIR/setup-kms.sh"; then
        state_complete "kms"
    else
        state_fail "kms"
        log_error "KMS setup failed"
        exit 1
    fi
else
    log_step "Step 2: KMS (Already Complete)"
fi

# Attach instance profile if not attached at launch
INSTANCE_ID=$(state_get "instance_id" 2>/dev/null || echo "")
if [[ -n "$INSTANCE_ID" ]]; then
    CURRENT_PROFILE=$(aws ec2 describe-iam-instance-profile-associations \
        --region "$AWS_REGION" \
        --filters "Name=instance-id,Values=$INSTANCE_ID" \
        --query 'IamInstanceProfileAssociations[0].State' \
        --output text 2>/dev/null || echo "")
    
    if [[ "$CURRENT_PROFILE" != "associated" ]]; then
        log_info "Attaching instance profile..."
        for i in {1..15}; do
            if aws ec2 associate-iam-instance-profile \
                --region "$AWS_REGION" \
                --instance-id "$INSTANCE_ID" \
                --iam-instance-profile Name=EnclaveInstanceProfile 2>/dev/null; then
                log_info "Profile attached!"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
        
        # Poll for IAM association status
         log_info "Waiting for IAM profile association (max 180s)..."
         ASSOC_OK=false
         for i in {1..90}; do
             STATE=$(aws ec2 describe-iam-instance-profile-associations \
                 --region "$AWS_REGION" \
                 --filters "Name=instance-id,Values=$INSTANCE_ID" \
                 --query 'IamInstanceProfileAssociations[0].State' \
                 --output text 2>/dev/null || echo "")
             if [[ "$STATE" == "associated" ]]; then
                 echo ""
                 log_info "Profile associated!"
                 ASSOC_OK=true
                 break
             fi
             echo -n "."
             sleep 2
         done
         echo ""
         if [[ "$ASSOC_OK" != "true" ]]; then
             log_error "Association failed or timed out. SSM cannot start."
             exit 1
         fi
        
        # Restart SSM and poll for online status
        log_info "Restarting SSM agent..."
        INSTANCE_IP=$(state_get "instance_ip" 2>/dev/null)
        KEY_PATH="$HOME/.ssh/$(state_get "key_name" 2>/dev/null || echo "nitro-enclave-key").pem"
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_PATH" ec2-user@"$INSTANCE_IP" \
            "sudo systemctl restart amazon-ssm-agent" 2>/dev/null || true
        
        log_info "Waiting for SSM agent to come online..."
        for i in {1..30}; do
            SSM_STATUS=$(aws ssm describe-instance-information \
                --region "$AWS_REGION" \
                --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
                --query 'InstanceInformationList[0].PingStatus' \
                --output text 2>/dev/null || echo "")
            if [[ "$SSM_STATUS" == "Online" ]]; then
                echo ""
                log_info "SSM agent online!"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
    fi
fi

# Step 3: Instance Setup via SSM (must be before Temporal on EC2)
if ! state_check "instance_setup"; then
    log_step "Step 3: Setting up EC2 Instance via SSM"
    state_start "instance_setup"
    
    if "$SCRIPT_DIR/run-instance-setup.sh"; then
        state_complete "instance_setup"
    else
        state_fail "instance_setup"
        log_error "Instance setup failed"
        exit 1
    fi
else
    log_step "Step 3: Instance Setup (Already Complete)"
fi

# Step 4: Temporal Server on EC2 via SSM
if ! state_check "temporal"; then
    log_step "Step 4: Setting up Temporal Server on EC2"
    state_start "temporal"
    
    if "$SCRIPT_DIR/run-temporal-ec2.sh"; then
        state_complete "temporal"
    else
        state_fail "temporal"
        log_error "Temporal setup failed"
        exit 1
    fi
else
    log_step "Step 4: Temporal (Already Complete)"
fi

# Step 5: Build Enclave via SSM
if ! state_check "enclave_built"; then
    log_step "Step 5: Building Enclave via SSM"
    state_start "enclave_built"
    
    if "$SCRIPT_DIR/run-enclave-build.sh"; then
        state_complete "enclave_built"
    else
        state_fail "enclave_built"
        log_error "Enclave build failed"
        exit 1
    fi
else
    log_step "Step 5: Enclave Build (Already Complete)"
fi

# Step 6: Apply KMS Attestation Policy
if ! state_check "kms_policy"; then
    log_step "Step 6: Applying KMS Attestation Policy"
    state_start "kms_policy"
    
    PCR0=$(state_get "pcr0" 2>/dev/null || echo "")
    if [[ -z "$PCR0" ]]; then
        log_error "PCR0 not found in state. Enclave may not have built correctly."
        exit 1
    fi
    
    if "$SCRIPT_DIR/setup-kms-policy.sh" "$PCR0"; then
        state_complete "kms_policy"
    else
        state_fail "kms_policy"
        log_error "KMS policy setup failed"
        exit 1
    fi
else
    log_step "Step 6: KMS Policy (Already Complete)"
fi

# Step 6.5: Deploy encrypted TSK to remote instance
log_info "Deploying encrypted TSK to EC2..."
if "$SCRIPT_DIR/deploy-tsk.sh"; then
    log_info "TSK deployed successfully"
else
    log_warn "TSK deployment failed - workflows may fail"
fi

# Step 7: Run Enclave via SSM
if ! state_check "enclave_running"; then
    log_step "Step 7: Starting Enclave via SSM"
    state_start "enclave_running"
    
    if "$SCRIPT_DIR/run-enclave-ssm.sh"; then
        state_complete "enclave_running"
    else
        state_fail "enclave_running"
        log_error "Enclave start failed"
        exit 1
    fi
else
    log_step "Step 7: Enclave Running (Already Complete)"
fi

# Step 8: Start Host Worker via SSM
if ! state_check "worker_running"; then
    log_step "Step 8: Starting Host Worker via SSM"
    state_start "worker_running"
    
    if "$SCRIPT_DIR/run-worker-ssm.sh"; then
        state_complete "worker_running"
    else
        state_fail "worker_running"
        log_error "Worker start failed"
        exit 1
    fi
else
    log_step "Step 8: Worker Running (Already Complete)"
fi

# Summary
log_step "Setup Complete!"

INSTANCE_IP=$(state_get "instance_ip" 2>/dev/null || echo "N/A")
PCR0=$(state_get "pcr0" 2>/dev/null || echo "N/A")
ENCLAVE_ID=$(state_get "enclave_id" 2>/dev/null || echo "N/A")

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│     All 8 Steps Completed!                 │"
echo "└─────────────────────────────────────────────┘"
echo ""
echo "Instance:   $INSTANCE_IP"
echo "PCR0:       ${PCR0:0:32}..."
echo "Enclave:    ${ENCLAVE_ID}"
echo ""
echo "Your confidential workflow is running!"
echo ""
echo "Next:"
echo "  - View status:  ./scripts/setup.sh --remote-status"
echo "  - SSH in:       ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${INSTANCE_IP}"
echo "  - View logs:    cat /tmp/enclave.log  |  cat /tmp/worker.log"
echo ""
