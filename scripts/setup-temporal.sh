#!/bin/bash
# Temporal Setup Script
# Sets up self-hosted Temporal using Docker Compose

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

NAMESPACE="confidential-workflow-poc"
TEMPORAL_DIR="./temporal-docker"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "Error: Docker not found"
    exit 1
fi

# Clone if needed
if [ -d "$TEMPORAL_DIR" ]; then
    log_warn "Temporal directory exists"
else
    log_info "Cloning Temporal Docker Compose..."
    git clone https://github.com/temporalio/docker-compose.git "$TEMPORAL_DIR"
fi
state_set "temporal_dir" "$TEMPORAL_DIR"

# Start Temporal
log_info "Starting Temporal services..."
cd "$TEMPORAL_DIR"
docker compose up -d
cd - > /dev/null

log_info "Waiting for Temporal..."
sleep 10

# Install CLI if needed
if ! command -v temporal &> /dev/null; then
    log_warn "Installing Temporal CLI..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install temporal
    else
        curl -sSf https://temporal.download/cli.sh | sh
        sudo mv temporal /usr/local/bin/
    fi
fi

# Create namespace
log_info "Creating namespace: $NAMESPACE"
temporal operator namespace create "$NAMESPACE" 2>/dev/null || log_warn "Namespace may exist"
state_set "temporal_namespace" "$NAMESPACE"
state_set "temporal_host" "localhost:7233"

# Save config
mkdir -p ./config
cat > ./config/temporal.env << EOF
TEMPORAL_HOST=localhost:7233
TEMPORAL_NAMESPACE=$NAMESPACE
TEMPORAL_TASK_QUEUE=confidential-workflow-queue
EOF

echo ""
echo "=========================================="
echo "Temporal Setup Complete!"
echo "Server:    localhost:7233"
echo "Web UI:    http://localhost:8080"
echo "Namespace: $NAMESPACE"
echo "=========================================="
echo ""

log_info "Temporal setup complete"
