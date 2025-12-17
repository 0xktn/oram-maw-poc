#!/bin/bash
# Run Enclave
# See docs/04-enclave-development.md for details

set -e

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EIF_PATH="$PROJECT_ROOT/build/enclave.eif"

# Source state management
source "$SCRIPT_DIR/lib/state.sh"

# Load configuration from state
CPU_COUNT=$(state_get "enclave_cpu_count" 2>/dev/null || echo "2")
MEMORY_MB=$(state_get "enclave_memory_mb" 2>/dev/null || echo "2048")
DEBUG_MODE=$(state_get "debug_mode" 2>/dev/null || echo "false")
# Assuming production mode if not explicitly set to false/debug in state
PRODUCTION_MODE=$(if [ "$DEBUG_MODE" = "true" ]; then echo "false"; else echo "true"; fi)

if [ ! -f "$EIF_PATH" ]; then
  echo "Error: Enclave image not found at $EIF_PATH"
  echo "Run scripts/build-enclave.sh first."
  exit 1
fi

# Production safety check
if [ "$PRODUCTION_MODE" = "true" ] && [ "$DEBUG_MODE" = "true" ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  WARNING: DEBUG MODE ENABLED IN PRODUCTION!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Debug mode disables Nitro Enclave security features."
  echo "This should NEVER be used in production environments."
  echo ""
  echo "To disable debug mode, set ENCLAVE_DEBUG_MODE=false"
  echo "in your .env file or environment variables."
  echo ""
  read -p "Continue anyway? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "Starting enclave..."
echo "  CPU Count: $CPU_COUNT"
echo "  Memory: ${MEMORY_MB}MB"
echo "  Debug Mode: $DEBUG_MODE"
echo "  Production Mode: $PRODUCTION_MODE"

if [ "$DEBUG_MODE" = "true" ]; then
  nitro-cli run-enclave \
    --cpu-count "$CPU_COUNT" \
    --memory "$MEMORY_MB" \
    --eif-path "$EIF_PATH" \
    --debug-mode
else
  nitro-cli run-enclave \
    --cpu-count "$CPU_COUNT" \
    --memory "$MEMORY_MB" \
    --eif-path "$EIF_PATH"
fi

echo ""
echo "Enclave started. Use 'nitro-cli describe-enclaves' to see status."
echo "Note the EnclaveCID for host worker configuration."
