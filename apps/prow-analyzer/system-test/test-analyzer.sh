#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# MCP URL
typeset mcpURL='https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp'
export SHIP_HELP_MCP_URL="${mcpURL}"

# Verify token is set via environment variable
if [[ -z "${SHIP_HELP_MCP_TOKEN:-}" ]]; then
    echo "Error: SHIP_HELP_MCP_TOKEN environment variable is not set" >&2
    echo "Usage: export SHIP_HELP_MCP_TOKEN='your-token' && $0" >&2
    exit 1
fi

typeset tokenLength="${#SHIP_HELP_MCP_TOKEN}"

# Test URL (the one we tested before)
typeset testURL='https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816'

: 'Testing prow-analyzer...'
: "MCP URL: ${mcpURL}"
: "Token: <set> (${tokenLength} chars)"

time ./prow-analyzer--cli analyze "${testURL}"

true
