#!/bin/bash
# Run Temporal on EC2 via SSM
# Installs Docker Compose and starts Temporal server

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
NAMESPACE="confidential-workflow-poc"

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "No instance ID found"
    exit 1
fi

log_info "Setting up Temporal server on EC2..."

# Create docker-compose.yml and run Temporal
COMMANDS='[
    "cd /home/ec2-user",
    "mkdir -p temporal-docker",
    "cd temporal-docker",
    "cat > docker-compose.yml << '\''COMPOSE'\''
services:
  postgresql:
    container_name: temporal-postgresql
    environment:
      POSTGRES_PASSWORD: temporal
      POSTGRES_USER: temporal
    image: postgres:17
    networks:
      - temporal-network
    expose:
      - 5432
    healthcheck:
      test: [\"CMD-SHELL\", \"pg_isready -U temporal\"]
      interval: 5s
      timeout: 5s
      retries: 10

  temporal:
    container_name: temporal
    depends_on:
      postgresql:
        condition: service_healthy
    environment:
      - DB=postgres12
      - DB_PORT=5432
      - POSTGRES_USER=temporal
      - POSTGRES_PWD=temporal
      - POSTGRES_SEEDS=postgresql
      - DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/development-sql.yaml
    image: temporalio/auto-setup:latest
    networks:
      - temporal-network
    ports:
      - 7233:7233
    volumes:
      - ./dynamicconfig:/etc/temporal/config/dynamicconfig
    healthcheck:
      test: [\"CMD\", \"tctl\", \"--address\", \"temporal:7233\", \"cluster\", \"health\"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 90s

  temporal-ui:
    container_name: temporal-ui
    depends_on:
      - temporal
    environment:
      - TEMPORAL_ADDRESS=temporal:7233
      - TEMPORAL_CORS_ORIGINS=http://localhost:3000
    image: temporalio/ui:latest
    networks:
      - temporal-network
    ports:
      - 8080:8080

networks:
  temporal-network:
    driver: bridge
    name: temporal-network
COMPOSE",
    "mkdir -p dynamicconfig",
    "echo \"{}\" > dynamicconfig/development-sql.yaml",
    "docker compose up -d 2>&1"
]'

COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=$COMMANDS" \
    --timeout-seconds 300 \
    --query 'Command.CommandId' \
    --output text)

log_info "Command sent: $COMMAND_ID"
log_info "Starting docker containers and waiting for Temporal to be ready (2-3 min)..."

# Wait for command
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
            log_info "Temporal setup completed!"
            break
            ;;
        "Failed"|"Cancelled"|"TimedOut")
            log_error "Temporal setup failed: $STATUS"
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

# Wait for Temporal to be healthy (using Docker's native healthcheck)
log_info "Waiting for Temporal to be healthy..."

# Simple inline health check loop
HEALTH_CHECK=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds 600 \
    --parameters 'commands=["for i in $(seq 1 60); do STATUS=$(docker inspect temporal --format={{.State.Health.Status}} 2>/dev/null || echo starting); echo Attempt $i: $STATUS; [ \"$STATUS\" = \"healthy\" ] && echo OK && exit 0; sleep 5; done; echo TIMEOUT; exit 1"]' \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

if [[ -z "$HEALTH_CHECK" ]]; then
    log_error "Failed to send health check command"
    exit 1
fi

log_info "Health check command: $HEALTH_CHECK"

# Wait for health check to complete
while true; do
    STATUS=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$HEALTH_CHECK" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Pending")
    
    case "$STATUS" in
        "Success")
            echo ""
            log_info "Temporal is ready!"
            break
            ;;
        "Failed"|"Cancelled"|"TimedOut")
            # Get the actual error
            ERROR=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$HEALTH_CHECK" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' \
                --output text 2>/dev/null)
            log_error "Health check failed: $STATUS"
            log_error "Error: $ERROR"
            exit 1
            ;;
        *)
            echo -n "."
            sleep 10
            ;;
    esac
done
echo ""

# Create namespace
log_info "Creating namespace: $NAMESPACE"
aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["docker exec temporal tctl --address temporal:7233 --namespace '"$NAMESPACE"' namespace register 2>&1 || echo Namespace already exists"]' \
    >/dev/null 2>&1

sleep 5

state_set "temporal_host" "localhost:7233"
state_set "temporal_namespace" "$NAMESPACE"
state_complete "temporal"

log_info "Temporal running on EC2 at localhost:7233"
