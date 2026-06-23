#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Test URL extraction logic (what Slack bot uses to detect Prow URLs)

cd "${0%/*}/.."

go run - <<'GOEOF'
package main

import (
    "fmt"
    "os"
    "github.com/RedHatQE/OpenShift-LP-QE--Tools/apps/prow-analyzer/pkg/analyzer"
)

func main() {
    fmt.Println("═══════════════════════════════════════════════════════")
    fmt.Println("Testing URL Extraction (Slack Integration Component)")
    fmt.Println("═══════════════════════════════════════════════════════")
    fmt.Println()

    testCases := []struct {
        input    string
        desc     string
    }{
        {
            "Check this failure: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/123",
            "Plain URL in message",
        },
        {
            "<https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/456>",
            "Slack-formatted URL (angle brackets)",
        },
        {
            "Failed: https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/789)",
            "URL with trailing punctuation",
        },
        {
            "Check <https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/abc|this link>",
            "Slack link with label",
        },
        {
            "No Prow URL here, just regular text about CI",
            "No URL present",
        },
        {
            "Multiple links but https://prow.ci.openshift.org/view/gs/test-platform-results/logs/job/xyz is the important one",
            "URL in middle of text",
        },
    }

    passed := 0
    for i, tc := range testCases {
        url := analyzer.ExtractProwURL(tc.input)
        
        fmt.Printf("Test %d: %s\n", i+1, tc.desc)
        fmt.Printf("  Input:  %s\n", tc.input)
        if url != "" {
            fmt.Printf("  ✅ Extracted: %s\n", url)
            passed++
        } else {
            fmt.Printf("  ❌ No URL found\n")
        }
        fmt.Println()
    }

    fmt.Printf("═══════════════════════════════════════════════════════\n")
    fmt.Printf("Result: %d/%d URLs extracted successfully\n", passed, len(testCases)-1) // -1 because one test has no URL
    fmt.Printf("═══════════════════════════════════════════════════════\n")

    expected := len(testCases) - 1 // One test case has no URL
    if passed != expected {
        os.Exit(1)
    }
}
GOEOF
