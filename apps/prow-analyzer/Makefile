.PHONY: test test-coverage build build-cli build-bot clean

# Build both binaries
build: build-cli build-bot

# Build CLI
build-cli:
	go build -o prow-analyzer--cli ./cmd/prow-analyzer--cli

# Build Bot
build-bot:
	go build -o prow-analyzer--bot ./cmd/prow-analyzer--bot

# Run tests
test:
	go test -v -race ./...

# Run tests with coverage and enforce threshold
test-coverage:
	@./scripts/test-coverage.sh

# Clean build artifacts
clean:
	rm -f prow-analyzer--cli prow-analyzer--bot
	rm -f coverage.out coverage.html

# Help
help:
	@echo "Prow Analyzer - Available targets:"
	@echo "  build           - Build both CLI and Bot binaries"
	@echo "  build-cli       - Build CLI binary only"
	@echo "  build-bot       - Build Bot binary only"
	@echo "  test            - Run unit tests with race detector"
	@echo "  test-coverage   - Run tests with coverage (enforces 94% threshold)"
	@echo "  clean           - Remove build artifacts and coverage reports"
