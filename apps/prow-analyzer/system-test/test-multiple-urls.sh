#!/bin/bash
set -e

export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token.txt | tr -d '\n')"

echo "=== Testing Prow Analyzer with Multiple URLs ==="
echo ""

# Test 1: Quick failure (should be fast)
echo "Test 1: Recent failure"
TEST_URL_1="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-openshift-release-master-ci-4.18-e2e-aws-ovn-upgrade/1934670912345678912"

echo "URL: $TEST_URL_1"
time ./prow-analyzer analyze "$TEST_URL_1" 2>&1 | head -30
echo ""
echo "---"
echo ""

# Test 2: Invalid URL (should fail gracefully)
echo "Test 2: Invalid URL - Error handling"
TEST_URL_2="https://prow.ci.openshift.org/invalid"

echo "URL: $TEST_URL_2"
./prow-analyzer analyze "$TEST_URL_2" 2>&1 || echo "Exit code: $? (expected failure)"
echo ""
echo "---"
echo ""

echo "=== All Tests Complete ==="
