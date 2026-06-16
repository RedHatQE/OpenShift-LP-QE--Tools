FROM registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.22-openshift-4.18 AS builder
WORKDIR /go/src/github.com/oramraz/prow-analyzer
COPY . .
RUN go build -o /prow-analyzer ./cmd/prow-analyzer--cli && \
    go build -o /prow-analyzer-bot ./cmd/prow-analyzer--bot

FROM registry.ci.openshift.org/ocp/4.18:base-rhel9
COPY --from=builder /prow-analyzer /usr/bin/
COPY --from=builder /prow-analyzer-bot /usr/bin/
USER 1000:1000
