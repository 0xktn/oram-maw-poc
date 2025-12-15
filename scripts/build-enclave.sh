#!/bin/bash
# Build Enclave Image (EIF)
# See docs/04-enclave-development.md for details

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENCLAVE_DIR="$PROJECT_ROOT/enclave"
OUTPUT_DIR="$PROJECT_ROOT/build"

# Set artifacts path for nitro-cli
export NITRO_CLI_ARTIFACTS="$OUTPUT_DIR"

echo "Building enclave Docker image..."
docker build --pull -t confidential-enclave:latest "$ENCLAVE_DIR"

echo "Creating output directory..."
mkdir -p "$OUTPUT_DIR"

echo "Building Enclave Image File (EIF)..."
BUILD_OUTPUT=$(nitro-cli build-enclave \
  --docker-uri confidential-enclave:latest \
  --output-file "$OUTPUT_DIR/enclave.eif" 2>&1)

echo "$BUILD_OUTPUT"

# Extract and display PCR0
PCR0=$(echo "$BUILD_OUTPUT" | grep -o '"PCR0": "[^"]*"' | cut -d'"' -f4)

if [[ -n "$PCR0" ]]; then
    echo ""
    echo "=========================================="
    echo "Enclave built successfully!"
    echo "PCR0: $PCR0"
    echo "EIF:  $OUTPUT_DIR/enclave.eif"
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "Build output above. Look for PCR0 value."
    echo "=========================================="
fi
