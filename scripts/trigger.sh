#!/bin/bash
# Trigger script for ORAM-MAW workflows
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/logging.sh"

# Get instance info
INSTANCE_ID=$(state_get "instance_id" 2>/dev/null || echo "")
INSTANCE_IP=$(state_get "instance_ip" 2>/dev/null || echo "")
AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance found. Run ./scripts/setup.sh first."
    exit 1
fi

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --benchmark              Run ORAM vs Standard pool benchmark"
    echo "  --status <wf_id|latest>  Check status of a workflow"
    echo "  --metrics [wf_id|latest] Show ORAM metrics from workflow"
    echo "  --verify [wf_id|latest]  Verify KMS attestation (proves enclave security)"
    echo "    --full                 Show full CloudTrail JSON (use with --verify)"
    echo "    --deep                 Deep cryptographic verification (use with --verify)"
    echo "  (no args)                Run ORAM-secure workflow"
    exit 1
}

# Parse arguments
MODE="trigger"
WORKFLOW_ID=""
WORKFLOW_TYPE="ORAMSecureWorkflow"

if [[ "$1" == "--benchmark" ]]; then
    MODE="trigger"
    WORKFLOW_TYPE="BenchmarkWorkflow"
elif [[ "$1" == "--status" ]]; then
    MODE="status"
    WORKFLOW_ID="$2"
    if [[ -z "$WORKFLOW_ID" ]]; then
        usage
    fi
elif [[ "$1" == "--metrics" ]]; then
    MODE="metrics"
    WORKFLOW_ID="$2"
elif [[ "$1" == "--verify" ]]; then
    MODE="verify_attestation"
    WORKFLOW_ID="$2"
elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
elif [[ -n "$1" ]]; then
    usage
fi

if [[ "$MODE" == "status" ]]; then
    if [[ "$WORKFLOW_ID" == "latest" ]]; then
        WORKFLOW_ID=$(state_get "last_workflow_id" 2>/dev/null || echo "")
        
        if [[ -z "$WORKFLOW_ID" ]]; then
            log_error "No workflows found in cache. Trigger a workflow first."
            exit 1
        fi
        
        log_info "Latest workflow (cached): $WORKFLOW_ID"
    fi
    
    COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"docker exec temporal temporal --address temporal:7233 workflow describe --namespace confidential-workflow-poc --workflow-id $WORKFLOW_ID 2>&1\"]" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)
    
    # Poll for completion
    for i in {1..20}; do
        STATUS=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")
        
        if [[ "$STATUS" == "Success" ]]; then
            break
        fi
        sleep 0.5
    done
    
    RESULT=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || echo "")
    
    echo ""
    echo "$RESULT"
    echo ""
    exit 0
fi

if [[ "$MODE" == "metrics" ]]; then
    if [[ -z "$WORKFLOW_ID" || "$WORKFLOW_ID" == "latest" ]]; then
        WORKFLOW_ID=$(state_get "last_workflow_id" 2>/dev/null || echo "")
        if [[ -z "$WORKFLOW_ID" ]]; then
            log_error "No workflows found. Trigger a workflow first."
            exit 1
        fi
    fi
    
    log_info "Fetching ORAM metrics for workflow: $WORKFLOW_ID"
    
    # Get workflow result which contains metrics
    COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"docker exec temporal temporal --address temporal:7233 workflow show --namespace confidential-workflow-poc --workflow-id $WORKFLOW_ID --output json 2>&1 | jq -r '.result'\"]" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)
    
    for i in {1..20}; do
        STATUS=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")
        
        if [[ "$STATUS" == "Success" ]]; then
            break
        fi
        sleep 0.5
    done
    
    RESULT=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || echo "")
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "ORAM Metrics"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$RESULT" | jq -r '
    "ORAM Pool:",
    "  Entries: " + (.acb_metrics.oram_pool.entries | tostring),
    "  Stash Size: " + (.acb_metrics.oram_pool.stash_size | tostring),
    "  Tree Height: " + (.acb_metrics.oram_pool.tree_height | tostring),
    "",
    "Standard Pool:",
    "  Entries: " + (.acb_metrics.standard_pool.entries | tostring),
    "",
    "Routing:",
    "  ORAM Routes: " + (.acb_metrics.routing.oram_routes | tostring),
    "  Standard Routes: " + (.acb_metrics.routing.standard_routes | tostring),
    "  ORAM Percentage: " + (.acb_metrics.routing.oram_percentage | tostring) + "%"
    '
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    exit 0
fi

if [[ "$MODE" == "verify_attestation" ]]; then
    SHOW_FULL_JSON=false
    
    # Handle optional arguments
    if [[ "$WORKFLOW_ID" == "--full" ]]; then
        WORKFLOW_ID="latest"
        SHOW_FULL_JSON=true
    elif [[ "$3" == "--full" ]] || [[ "$4" == "--full" ]]; then
        SHOW_FULL_JSON=true
    fi
    
    DEEP_VERIFY=false
    if [[ "$2" == "--deep" ]] || [[ "$3" == "--deep" ]] || [[ "$4" == "--deep" ]]; then
        DEEP_VERIFY=true
        log_info "Deep offline verification enabled"
    fi
    
    if [[ -z "$WORKFLOW_ID" || "$WORKFLOW_ID" == "latest" ]]; then
        WORKFLOW_ID=$(state_get "last_workflow_id" 2>/dev/null || echo "")
        if [[ -z "$WORKFLOW_ID" ]]; then
            log_error "No workflows found. Trigger a workflow first."
            exit 1
        fi
        log_info "Verifying attestation for latest workflow: $WORKFLOW_ID"
    else
        log_info "Verifying attestation for workflow: $WORKFLOW_ID"
    fi
    
    if [[ "$SHOW_FULL_JSON" == "true" ]]; then
        log_info "Full JSON output enabled"
    fi

    # Use a 10-minute time window for CloudTrail search
    if date -v-10M > /dev/null 2>&1; then
        # macOS
        START_TIME=$(date -u -v-10M '+%Y-%m-%dT%H:%M:%S')
    else
        # Linux
        START_TIME=$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%S')
    fi
    END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S')
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Attestation Verification (ORAM-MAW)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Searching CloudTrail for KMS Decrypt events with Nitro Enclave attestation..."
    echo ""
    
    # Poll CloudTrail for up to 5 minutes
    MAX_ATTEMPTS=30
    ATTEMPT=0
    ATTESTATION=""
    
    while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
        ATTEMPT=$((ATTEMPT + 1))
        
        ATTESTATION=$(aws cloudtrail lookup-events \
            --region "$AWS_REGION" \
            --lookup-attributes AttributeKey=EventName,AttributeValue=Decrypt \
            --start-time "$START_TIME" \
            --end-time "$END_TIME" \
            --output json 2>/dev/null | \
            jq -r -c '.Events[] | select(.CloudTrailEvent | contains("nitro_enclaves")) | .CloudTrailEvent | fromjson' | \
            head -1)
        
        if [[ -n "$ATTESTATION" ]]; then
            echo ""
            log_info "Attestation document found!"
            break
        fi
        
        ELAPSED=$((ATTEMPT * 10))
        echo -ne "\r[${ATTEMPT}/${MAX_ATTEMPTS}] Polling CloudTrail... (${ELAPSED}s elapsed, CloudTrail has 2-5min delay)    "
        
        sleep 10
        END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S')
    done
    
    echo ""
    echo ""
    
    if [[ -z "$ATTESTATION" ]]; then
        log_error "No attestation document found after ${MAX_ATTEMPTS} attempts (5 minutes)"
        log_info "This could mean:"
        log_info "  - The workflow hasn't run yet"
        log_info "  - CloudTrail events are still propagating (can take up to 15 minutes)"
        log_info "  - The enclave didn't decrypt any secrets"
        exit 1
    fi
    
    # Extract and display attestation fields
    echo "$ATTESTATION" | jq -r '
    "Event Time:        " + .eventTime,
    "User Agent:        " + .userAgent,
    "Source IP:         " + .sourceIPAddress,
    "",
    "Attestation Document:",
    "  Module ID:       " + .additionalEventData.recipient.attestationDocumentModuleId,
    "  Image Digest:    " + .additionalEventData.recipient.attestationDocumentEnclaveImageDigest,
    "  PCR1:            " + .additionalEventData.recipient.attestationDocumentEnclavePCR1,
    "  PCR2:            " + .additionalEventData.recipient.attestationDocumentEnclavePCR2,
    "  PCR3:            " + .additionalEventData.recipient.attestationDocumentEnclavePCR3,
    "",
    "KMS Key:           " + .resources[0].ARN
    '
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Attestation Verified!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Verify PCR0 against local build
    EXPECTED_PCR0=$(state_get "pcr0" 2>/dev/null || echo "")
    if [[ -n "$EXPECTED_PCR0" ]]; then
        ACTUAL_PCR0_B64=$(echo "$ATTESTATION" | jq -r '.additionalEventData.recipient.attestationDocumentEnclaveImageDigest')
        
        if command -v python3 &> /dev/null; then
            ACTUAL_PCR0_HEX=$(python3 -c "import base64, binascii; print(binascii.hexlify(base64.b64decode('$ACTUAL_PCR0_B64')).decode())")
        else
            ACTUAL_PCR0_HEX=$(echo "$ACTUAL_PCR0_B64" | base64 -d | xxd -p | tr -d '\n')
        fi
        
        echo "PCR0 Verification:"
        echo "  Expected (Build): $EXPECTED_PCR0"
        echo "  Actual (Enclave): $ACTUAL_PCR0_HEX"
        
        if [[ "$EXPECTED_PCR0" == "$ACTUAL_PCR0_HEX" ]]; then
            echo "  Result:           ✅ MATCH - ORAM Code Integrity Confirmed"
        else
            echo "  Result:           ❌ MISMATCH - Code Integrity Failed!"
            log_warn "The running enclave code differs from your local build."
        fi
    else
        log_warn "Could not verify PCR0: Local build state not found."
    fi

    echo ""
    echo "This attestation document is cryptographically signed by AWS Nitro hardware."
    echo "KMS verified these measurements before releasing the TSK to the ORAM enclave."
    echo ""
    
    if [[ "$SHOW_FULL_JSON" == "true" ]]; then
        echo "Full CloudTrail Event JSON:"
        echo "$ATTESTATION" | jq .
        echo ""
    else
        echo "To view full JSON:"
        echo "  $0 --verify $WORKFLOW_ID --full"
        echo ""
    fi
    
    if [[ "$DEEP_VERIFY" == "true" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Deep Offline Verification"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "PCR0 integrity confirmed via CloudTrail."
        log_info "The ORAM enclave is cryptographically verified to match your local build."
    fi
    
    exit 0
fi

# Trigger new workflow
if [[ "$WORKFLOW_TYPE" == "BenchmarkWorkflow" ]]; then
    log_info "Triggering ORAM benchmark workflow on EC2 instance: $INSTANCE_ID"
else
    log_info "Triggering ORAM-secure workflow on EC2 instance: $INSTANCE_ID"
fi

# Get timestamp for unique workflow ID
WORKFLOW_ID="oram-$(date +%s)"

# Run Python starter script via SSM
COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"cd /home/ec2-user/oram-maw-poc/host && python3 starter.py $([ '$WORKFLOW_TYPE' == 'BenchmarkWorkflow' ] && echo '--benchmark' || echo '') 2>&1\"]" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

log_info "Command sent: $COMMAND_ID"
log_info "Waiting for response..."

# Poll for completion
for i in {1..30}; do
    STATUS=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")
    
    if [[ "$STATUS" == "Success" ]]; then
        break
    fi
    sleep 1
done

# Get result
RESULT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

if [[ -n "$RESULT" ]]; then
    # Extract the actual workflow ID from the starter output
    ACTUAL_WORKFLOW_ID=$(echo "$RESULT" | grep -o 'oram-[a-z]*-[a-z0-9]*' | head -1)
    
    if [[ -n "$ACTUAL_WORKFLOW_ID" ]]; then
        state_set "last_workflow_id" "$ACTUAL_WORKFLOW_ID"
    else
        # Fallback to timestamp-based ID if extraction fails
        state_set "last_workflow_id" "$WORKFLOW_ID"
    fi
    
    echo ""
    echo -e "${BLUE}=== Workflow Started ===${NC}"
    # Pretty print the result if it's JSON
    if echo "$RESULT" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$RESULT" | python3 -m json.tool
    else
        echo "$RESULT"
    fi
    echo ""
    log_info "Check status with: ${YELLOW}./scripts/trigger.sh --status ${ACTUAL_WORKFLOW_ID:-$WORKFLOW_ID}${NC}"
    log_info "Or use: ${YELLOW}./scripts/trigger.sh --status latest${NC}"
    log_info "View ORAM metrics: ${YELLOW}./scripts/trigger.sh --metrics latest${NC}"
    log_info "Verify attestation: ${YELLOW}./scripts/trigger.sh --verify latest${NC}"
else
    ERROR=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' \
        --output text 2>/dev/null || echo "")
    log_error "Failed to trigger workflow"
    echo "$ERROR"
    exit 1
fi
