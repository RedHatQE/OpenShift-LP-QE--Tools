#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset mcpURL='https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp'
export SHIP_HELP_MCP_URL="${mcpURL}"

# Verify token is set via environment variable
if [[ -z "${SHIP_HELP_MCP_TOKEN:-}" ]]; then
    echo "Error: SHIP_HELP_MCP_TOKEN environment variable is not set" >&2
    echo "Usage: export SHIP_HELP_MCP_TOKEN='your-token' && $0" >&2
    exit 1
fi

: '=== Testing Prow Analyzer with Multiple URLs ==='

# Test 1: Quick failure (should be fast)
: 'Test 1: Recent failure'
typeset testURL1='https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-release-master-ci-4.18-e2e-aws-ovn-upgrade/1934670912345678912'

: "URL: ${testURL1}"
./prow-analyzer--cli analyze "${testURL1}" > /tmp/test-output.txt 2>&1
: 'Output preview (first 30 lines):'
head -30 /tmp/test-output.txt
: '---'

# Test 2: Invalid URL (should fail gracefully)
: 'Test 2: Invalid URL - Error handling'
typeset testURL2='https://prow.ci.openshift.org/invalid'

: "URL: ${testURL2}"
typeset -i exitCode=0
./prow-analyzer--cli analyze "${testURL2}" 2>&1 || exitCode=$?
: "Exit code: ${exitCode} (expected non-zero for invalid URL)"
if ((exitCode == 0)); then
    : '❌ FAIL: Command should have failed on invalid URL'
    exit 1
fi
: '✅ PASS: Invalid URL rejected correctly'
: '---'

: '=== All Tests Complete ==='

true
