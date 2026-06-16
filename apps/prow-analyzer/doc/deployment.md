# Deployment Guide

## Prerequisites

1. **Ship-help MCP Token**
   - Get from #ship-users in Slack
   - Or reuse existing token from ship-help-bot

2. **Slack App** (for bot only)
   - Create at https://api.slack.com/apps
   - Enable Socket Mode
   - Required scopes: `channels:history`, `chat:write`, `app_mentions:read`
   - Get Bot Token (xoxb-...) and App Token (xapp-...)

3. **OpenShift Access** (for production deployment)
   - Access to app.ci cluster or your team's cluster
   - Permissions to create namespace/deployment

## Option 1: Local Testing (Laptop)

```bash
# Set environment variables
export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="$(cat /path/to/token.txt | tr -d '\n')"
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_APP_TOKEN="xapp-..."
export MONITORED_CHANNELS="C12345678"  # Your channel ID

# Build (requires Go 1.22+)
go build ./cmd/prow-analyzer--bot

# Run
./prow-analyzer--bot
```

**Test it:**
Post a Prow URL in your monitored channel and watch for bot response.

## Option 2: OpenShift Deployment

### Step 1: Build and Push Image

```bash
# Login to Quay
podman login quay.io

# Build image
podman build -t quay.io/<your-org>/prow-analyzer-bot:latest .

# Push to registry
podman push quay.io/<your-org>/prow-analyzer-bot:latest
```

### Step 2: Create Secrets

```bash
# Create namespace
oc create namespace prow-analyzer

# Create secrets (replace with actual values)
oc create secret generic prow-analyzer-secrets \
  --from-literal=ship-help-token="YOUR_TOKEN_HERE" \
  --from-literal=slack-bot-token="xoxb-..." \
  --from-literal=slack-app-token="xapp-..." \
  -n prow-analyzer
```

### Step 3: Update Configuration

Edit `deploy/openshift/deployment.yaml`:

```yaml
# Update monitored-channels in ConfigMap
data:
  monitored-channels: "C12345678,C87654321"  # Your actual channel IDs
```

### Step 4: Deploy

```bash
oc apply -f deploy/openshift/deployment.yaml
```

### Step 5: Verify

```bash
# Check pod status
oc get pods -n prow-analyzer

# Check logs
oc logs -f deployment/prow-analyzer-bot -n prow-analyzer
```

## Option 3: Deploy to app.ci Cluster

Same as Option 2, but:
- Use namespace on app.ci cluster
- Image might already be accessible if using ci-operator
- May need approval from cluster admins

## Getting Channel IDs

**Method 1: Slack URL**
```
https://app.slack.com/client/T09NY5SBT/C12345678
                                      ^^^^^^^^^
                                      Channel ID
```

**Method 2: Right-click channel → View channel details → bottom of popup**

## Troubleshooting

### Bot not responding

1. Check logs: `oc logs -f deployment/prow-analyzer-bot`
2. Verify channel ID is correct
3. Ensure bot is invited to channel
4. Check tokens are valid

### MCP authentication errors

- Token may have trailing newline: `tr -d '\n'`
- Token may have expired
- Wrong MCP URL

### Build failures

- Requires Go 1.22+
- Run `go mod tidy` first
- Check network access for dependencies

## Monitoring

```bash
# Watch logs
oc logs -f deployment/prow-analyzer-bot -n prow-analyzer

# Check resource usage
oc top pod -n prow-analyzer

# Restart if needed
oc rollout restart deployment/prow-analyzer-bot -n prow-analyzer
```
