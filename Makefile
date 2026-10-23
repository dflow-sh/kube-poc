# Build the dflow CLI.
# On a Mac, `make dflow` writes dist/dflow for that Mac.
# `make dflow-darwin` writes both darwin-arm64 and darwin-amd64 binaries.

GO ?= go

.PHONY: dflow dflow-darwin dflow-linux vet

# go vet and staticcheck. staticcheck is 2026.2.2.
STATICCHECK_VERSION ?= v0.8.2

vet:
	$(GO) vet ./...
	$(GO) run honnef.co/go/tools/cmd/staticcheck@$(STATICCHECK_VERSION) ./...

dflow:
	mkdir -p dist
	CGO_ENABLED=0 $(GO) build -o dist/dflow ./apps/cli

dflow-darwin:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 $(GO) build -o dist/dflow-darwin-arm64 ./apps/cli
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 $(GO) build -o dist/dflow-darwin-amd64 ./apps/cli

dflow-linux:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -o dist/dflow-linux-amd64 ./apps/cli
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -o dist/dflow-linux-arm64 ./apps/cli
