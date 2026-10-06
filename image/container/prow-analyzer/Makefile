.PHONY: build push clean help

SHELL := /bin/bash

IMAGE_REGISTRY  ?= images.paas.redhat.com
IMAGE_NAMESPACE ?= ieng/app
IMAGE_REPO      ?= prow-analyzer
IMAGE_TAG       ?= latest
IMAGE_NAME       = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):$(IMAGE_TAG)
IMAGE_LATEST     = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):latest

# Application source directory (relative to repo root)
APP_DIR = apps/prow-analyzer

# Build container image. xtrace (-x) renders each command after Make/shell
# interpolation, so `:` no-ops double as progress messages.
build:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Building container image: $(IMAGE_FULL)';\
	    podman build $(BUILDFLAGS) -t '$(IMAGE_FULL)' -f Dockerfile '../../../$(APP_DIR)';\
	}

# Push container image to registry
push: build
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Pushing container image: $(IMAGE_FULL)';\
	    podman push '$(IMAGE_FULL)';\
	}

# Clean local image
clean:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Removing local image: $(IMAGE_FULL)';\
	    podman rmi '$(IMAGE_FULL)' || true;\
	}

# Help
help:
	@printf '%s\n' \
		'Prow Analyzer Container Build' \
		'' \
		'Available targets:' \
		'  build  - Build container image (default: $(IMAGE_FULL))' \
		'  push   - Build and push container image to registry' \
		'  clean  - Remove local container image' \
		'' \
		'Variables:' \
		'  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))' \
		'  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))' \
		'  IMAGE_NAME      - Image name (default: $(IMAGE_NAME))' \
		'  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))' \
		'' \
		'Example:' \
		'  make build IMAGE_TAG=v1.0.0' \
		'  make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg IMAGE_TAG=v1.0.0'
