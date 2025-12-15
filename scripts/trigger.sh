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
        --parameters "commands=[\"docker exec temporal temporal --address temporal:7233 workflow describe --namespace oram-maw-poc --workflow-id $WORKFLOW_ID 2>&1\"]" \
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
        --parameters "commands=[\"docker exec temporal temporal --address temporal:7233 workflow show --namespace oram-maw-poc --workflow-id $WORKFLOW_ID --output json 2>&1 | jq -r '.result'\"]" \
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
    state_set "last_workflow_id" "$WORKFLOW_ID"
    
    echo ""
    echo "=== Workflow Started ==="
    echo "$RESULT"
    echo ""
    log_info "Check status with: ./scripts/trigger.sh --status $WORKFLOW_ID"
    log_info "Or use: ./scripts/trigger.sh --status latest"
    
    if [[ "$WORKFLOW_TYPE" == "ORAMSecureWorkflow" ]]; then
        log_info "View ORAM metrics: ./scripts/trigger.sh --metrics latest"
    fi
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
