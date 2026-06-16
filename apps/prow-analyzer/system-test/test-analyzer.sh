#!/bin/bash
set -e

# MCP URL
export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"

# Token (from file, trimmed)
if [ -f /tmp/ship-help-token-clean.txt ]; then
    export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token-clean.txt)"
elif [ -f /tmp/ship-help-token.txt ]; then
    export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token.txt | tr -d '\n')"
else
    echo "Error: No token file found"
    echo "Expected: /tmp/ship-help-token-clean.txt or /tmp/ship-help-token.txt"
    exit 1
fi

# Test URL (the one we tested before)
TEST_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816"

echo "Testing prow-analyzer..."
echo "MCP URL: $SHIP_HELP_MCP_URL"
echo "Token: ${SHIP_HELP_MCP_TOKEN:0:20}... (${#SHIP_HELP_MCP_TOKEN} chars)"
echo ""

time ./prow-analyzer--cli analyze "$TEST_URL"
