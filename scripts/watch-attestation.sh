#!/bin/bash
# Watch CloudTrail for Nitro Enclave attestation events in real-time
# Usage: ./scripts/watch-attestation.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/state.sh"

AWS_REGION=$(state_get "aws_region" 2>/dev/null || echo "ap-southeast-1")

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Watching CloudTrail for Nitro Enclave Attestation Events"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${YELLOW}Note: CloudTrail events have a 2-5 minute delay${NC}"
echo "Press Ctrl+C to stop"
echo ""

# Track last seen event time to avoid duplicates
LAST_EVENT_TIME=""

while true; do
    # Get events from last 10 minutes
    if date -v-10M > /dev/null 2>&1; then
        # macOS
        START_TIME=$(date -u -v-10M '+%Y-%m-%dT%H:%M:%S')
    else
        # Linux
        START_TIME=$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%S')
    fi
    END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S')
    
    # Fetch CloudTrail events
    EVENTS=$(aws cloudtrail lookup-events \
        --region "$AWS_REGION" \
        --lookup-attributes AttributeKey=EventName,AttributeValue=Decrypt \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --output json 2>/dev/null | \
        jq -r '.Events[] | select(.CloudTrailEvent | contains("nitro_enclaves")) | .CloudTrailEvent | fromjson | 
        {
            eventTime: .eventTime,
            userAgent: .userAgent,
            sourceIP: .sourceIPAddress,
            moduleId: .additionalEventData.recipient.attestationDocumentModuleId,
            imageDigest: .additionalEventData.recipient.attestationDocumentEnclaveImageDigest
        }' 2>/dev/null)
    
    if [[ -n "$EVENTS" ]]; then
        # Parse each event
        while IFS= read -r event; do
            EVENT_TIME=$(echo "$event" | jq -r '.eventTime')
            
            # Skip if we've already seen this event
            if [[ "$EVENT_TIME" == "$LAST_EVENT_TIME" ]]; then
                continue
            fi
            
            # New event found!
            LAST_EVENT_TIME="$EVENT_TIME"
            
            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}✅ NEW ATTESTATION EVENT DETECTED${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            echo "$event" | jq -r '
            "Event Time:    " + .eventTime,
            "User Agent:    " + .userAgent,
            "Source IP:     " + .sourceIP,
            "",
            "Attestation:",
            "  Module ID:   " + .moduleId,
            "  PCR0 Digest: " + .imageDigest
            '
            echo ""
            
        done < <(echo "$EVENTS" | jq -c '.')
    fi
    
    # Show timestamp and wait
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    echo -ne "\r${CYAN}[${NOW}]${NC} Checking CloudTrail... (last event: ${LAST_EVENT_TIME:-none})    "
    
    sleep 10
done
