#!/bin/bash
# Simulate what happens when Slack bot receives a message

echo "═══════════════════════════════════════════════════════"
echo "Slack Bot Integration Simulation"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "This simulates the Slack bot workflow WITHOUT actually"
echo "connecting to Slack (no tokens needed)."
echo ""

# Simulate Slack message event
SLACK_MESSAGE="Hey team, check this failure: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816"

echo "📱 Simulated Slack Message:"
echo "   Channel: #opp-discussion"
echo "   User: @developer"
echo "   Text: $SLACK_MESSAGE"
echo ""

# Step 1: URL Extraction (what the bot does)
echo "Step 1: Bot extracts Prow URL from message..."
cd ~/prow-analyzer
export PATH=$PATH:/usr/local/go/bin

cat > /tmp/extract-url.go << 'GOEOF'
package main
import (
	"fmt"
	"os"
	"github.com/oramraz/prow-analyzer/pkg/analyzer"
)
func main() {
	url := analyzer.ExtractProwURL(os.Args[1])
	if url != "" {
		fmt.Printf("✅ URL detected: %s\n", url)
	} else {
		fmt.Println("❌ No Prow URL found")
	}
}
GOEOF

go run /tmp/extract-url.go "$SLACK_MESSAGE"
URL=$(go run /tmp/extract-url.go "$SLACK_MESSAGE" 2>/dev/null | grep -oP 'https://[^\s]+')
echo ""

# Step 2: Analysis (what the bot does in background)
echo "Step 2: Bot analyzes URL via ship-help MCP..."
echo "   (This takes ~2 minutes in production)"
echo ""

export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="$(cat /tmp/ship-help-token.txt | tr -d '\n')"

echo "⏱️  Running analysis..."
START=$(date +%s)
ANALYSIS=$(./prow-analyzer analyze "$URL" 2>&1)
END=$(date +%s)
DURATION=$((END - START))
echo "✅ Analysis completed in ${DURATION}s"
echo ""

# Step 3: Format for Slack (what the bot does)
echo "Step 3: Bot formats response for Slack thread..."
echo ""
echo "═══════════════════════════════════════════════════════"
echo "📨 Simulated Slack Thread Reply:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "$ANALYSIS" | head -40
echo ""
echo "... (truncated)"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "Bot Workflow Complete!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "In production:"
echo "  1. ✅ Bot monitors #opp-discussion via Socket Mode"
echo "  2. ✅ Detects Prow URL in message"
echo "  3. ✅ Analyzes via ship-help MCP (~2 min)"
echo "  4. ✅ Posts formatted analysis in thread"
echo ""
echo "What's NOT tested (needs Slack tokens):"
echo "  ❌ Socket Mode connection"
echo "  ❌ Channel authorization"
echo "  ❌ Thread reply posting"
echo "  ❌ Bot loop prevention"
