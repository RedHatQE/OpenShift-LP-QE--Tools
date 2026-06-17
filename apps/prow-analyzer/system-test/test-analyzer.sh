#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# MCP URL
typeset mcpURL='https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp'
export SHIP_HELP_MCP_URL="${mcpURL}"

# Token (from file, trimmed) - handle secrets without exposing in xtrace
set +x
if [ -f /tmp/ship-help-token-clean.txt ]; then
    export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token-clean.txt)"
elif [ -f /tmp/ship-help-token.txt ]; then
    export SHIP_HELP_MCP_TOKEN="$(tr -d '\n' < /tmp/ship-help-token.txt)"
else
    echo 'Error: No token file found' 1>&2
    echo 'Expected: /tmp/ship-help-token-clean.txt or /tmp/ship-help-token.txt' 1>&2
    exit 1
fi
typeset tokenLength="${#SHIP_HELP_MCP_TOKEN}"
set -x

# Test URL (the one we tested before)
typeset testURL='https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816'

: 'Testing prow-analyzer...'
: "MCP URL: ${mcpURL}"
: "Token: <set> (${tokenLength} chars)"

time ./prow-analyzer--cli analyze "${testURL}"

true
