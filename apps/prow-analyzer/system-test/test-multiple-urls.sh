#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset mcpURL='https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp'
export SHIP_HELP_MCP_URL="${mcpURL}"

set +x
export SHIP_HELP_MCP_TOKEN="$(tr -d '\n' < /tmp/ship-help-token.txt)"
set -x

echo '=== Testing Prow Analyzer with Multiple URLs ==='
echo ''

# Test 1: Quick failure (should be fast)
echo 'Test 1: Recent failure'
typeset testURL1='https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-release-master-ci-4.18-e2e-aws-ovn-upgrade/1934670912345678912'

echo "URL: ${testURL1}"
time ./prow-analyzer--cli analyze "${testURL1}" 2>&1 | head -30
echo ''
echo '---'
echo ''

# Test 2: Invalid URL (should fail gracefully)
echo 'Test 2: Invalid URL - Error handling'
typeset testURL2='https://prow.ci.openshift.org/invalid'

echo "URL: ${testURL2}"
typeset -i exitCode=0
./prow-analyzer--cli analyze "${testURL2}" 2>&1 || exitCode=$?
echo "Exit code: ${exitCode} (expected failure)"
echo ''
echo '---'
echo ''

echo '=== All Tests Complete ==='

true
