# ------------------------------------------------------------------------------
# prow-analyzer image (CLI + Slack bot).
#
# Unlike the OTE plugin image, this one is built by GitHub Actions
# (docker/build-push-action) and pushed to images.paas.redhat.com. That runner
# has no credentials for registry.ci.openshift.org, so pulling the OCP CI builder
# there fails with HTTP 401. We therefore use the publicly pullable Red Hat base
# images (registry.access.redhat.com), which need no authentication.
# ------------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/go-toolset:1.22 AS builder
WORKDIR /opt/app-root/src
# Build context is apps/prow-analyzer/ when called from image/container/prow-analyzer/Makefile.
# --chown keeps the copied sources owned by the non-root go-toolset build user so
# `go mod vendor` and `go build` can write alongside them.
COPY --chown=1001:0 . .
RUN <<'EOF'
set -euo pipefail
go mod vendor
CGO_ENABLED=0 go build -o /opt/app-root/src/prow-analyzer--cli ./cmd/prow-analyzer--cli
CGO_ENABLED=0 go build -o /opt/app-root/src/prow-analyzer--bot ./cmd/prow-analyzer--bot
EOF

FROM registry.access.redhat.com/ubi9/ubi:latest
COPY --from=builder /opt/app-root/src/prow-analyzer--cli /usr/bin/prow-analyzer--cli
COPY --from=builder /opt/app-root/src/prow-analyzer--bot /usr/bin/prow-analyzer--bot
USER 1000:1000
ENTRYPOINT ["/usr/bin/prow-analyzer--bot"]
