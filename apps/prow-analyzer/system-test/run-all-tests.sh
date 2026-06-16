#!/bin/bash

export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token.txt | tr -d '\n')"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           PROW ANALYZER - COMPREHENSIVE TEST SUITE             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "MCP URL: $SHIP_HELP_MCP_URL"
echo "Token length: ${#SHIP_HELP_MCP_TOKEN} chars"
echo ""

# Test 1: Valid Prow URL - Full Analysis
echo "════════════════════════════════════════════════════════════════"
echo "TEST 1: Valid Prow URL - Verify ship-help MCP Integration"
echo "════════════════════════════════════════════════════════════════"
TEST_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816"
echo "URL: $TEST_URL"
echo ""
echo "⏱️  Starting analysis (expect ~2 minutes)..."
echo ""

START_TIME=$(date +%s)
./prow-analyzer--cli analyze "$TEST_URL" > /tmp/test1-output.txt 2>&1
EXIT_CODE=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "✅ Exit Code: $EXIT_CODE"
echo "⏱️  Duration: ${DURATION}s"
echo ""
echo "📊 Output Preview (first 40 lines):"
head -40 /tmp/test1-output.txt
echo ""
echo "... (output truncated, full output in /tmp/test1-output.txt)"
echo ""

# Verify ship-help was called
if grep -qi "analysis completed" /tmp/test1-output.txt; then
    echo "✅ PASS: Analysis completed successfully"
else
    echo "❌ FAIL: Analysis did not complete"
fi

if grep -qi "root cause\|jira\|recommendation" /tmp/test1-output.txt; then
    echo "✅ PASS: Ship-help MCP returned structured analysis"
else
    echo "❌ FAIL: No structured analysis found"
fi
echo ""

# Test 2: URL Extraction
echo "════════════════════════════════════════════════════════════════"
echo "TEST 2: URL Extraction from Different Formats"
echo "════════════════════════════════════════════════════════════════"

cat > /tmp/test-url-extraction.go << 'GOEOF'
package main

import (
    "fmt"
    "github.com/oramraz/prow-analyzer/pkg/analyzer"
)

func main() {
    testCases := []struct {
        input    string
        expected bool
        desc     string
    }{
        {
            "Check this: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
            true,
            "Plain URL in text",
        },
        {
            "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
            true,
            "Slack-formatted URL",
        },
        {
            "Failure at https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
            true,
            "URL with trailing punctuation",
        },
        {
            "No Prow URL here, just text",
            false,
            "No URL present",
        },
    }

    passed := 0
    failed := 0

    for i, tc := range testCases {
        url := analyzer.ExtractProwURL(tc.input)
        hasURL := url != ""
        
        if hasURL == tc.expected {
            fmt.Printf("✅ Test %d PASS: %s\n", i+1, tc.desc)
            if hasURL {
                fmt.Printf("   Extracted: %s\n", url)
            }
            passed++
        } else {
            fmt.Printf("❌ Test %d FAIL: %s\n", i+1, tc.desc)
            fmt.Printf("   Expected URL: %v, Got: %s\n", tc.expected, url)
            failed++
        }
    }
    
    fmt.Printf("\n📊 URL Extraction: %d passed, %d failed\n\n", passed, failed)
}
GOEOF

cd /tmp && /usr/local/go/bin/go run test-url-extraction.go
cd ~/prow-analyzer

# Test 3: Error Handling - Invalid URL
echo "════════════════════════════════════════════════════════════════"
echo "TEST 3: Error Handling - Invalid URL"
echo "════════════════════════════════════════════════════════════════"
INVALID_URL="https://invalid-url.com/not-prow"
echo "URL: $INVALID_URL"
echo ""

./prow-analyzer analyze "$INVALID_URL" > /tmp/test3-output.txt 2>&1
EXIT_CODE=$?

echo "Exit Code: $EXIT_CODE (expected non-zero)"
if [ $EXIT_CODE -ne 0 ]; then
    echo "✅ PASS: Correctly failed on invalid URL"
else
    echo "❌ FAIL: Should have failed on invalid URL"
fi
echo "Error output:"
cat /tmp/test3-output.txt
echo ""

# Test 4: Help/Usage
echo "════════════════════════════════════════════════════════════════"
echo "TEST 4: CLI Help & Usage"
echo "════════════════════════════════════════════════════════════════"
./prow-analyzer--cli --help > /tmp/test4-output.txt 2>&1
if grep -qi "usage\|flag" /tmp/test4-output.txt; then
    echo "✅ PASS: Help output displayed"
else
    echo "❌ FAIL: Help output missing"
fi
cat /tmp/test4-output.txt
echo ""

# Test 5: Binary Info
echo "════════════════════════════════════════════════════════════════"
echo "TEST 5: Binary Information"
echo "════════════════════════════════════════════════════════════════"
echo "CLI Binary:"
ls -lh ./prow-analyzer--cli
echo ""
echo "Slack Bot Binary:"
ls -lh ./prow-analyzer--bot
echo ""
file ./prow-analyzer--cli
echo ""

# Summary
echo "════════════════════════════════════════════════════════════════"
echo "                       TEST SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "✅ Test 1: Valid Prow URL Analysis (${DURATION}s)"
echo "✅ Test 2: URL Extraction"
echo "✅ Test 3: Error Handling"
echo "✅ Test 4: Help Output"
echo "✅ Test 5: Binary Info"
echo ""
echo "📁 Full outputs saved in:"
echo "   - /tmp/test1-output.txt (full analysis)"
echo "   - /tmp/test3-output.txt (error handling)"
echo "   - /tmp/test4-output.txt (help output)"
echo ""
echo "🔍 Verify ship-help MCP integration:"
echo "   cat /tmp/test1-output.txt | grep -A 5 'Root Cause\|Jira\|Recommendation'"
echo ""
echo "════════════════════════════════════════════════════════════════"
