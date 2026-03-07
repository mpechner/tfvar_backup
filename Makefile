BINARY_BACKUP        := tfvar-backup
BINARY_CREATE        := tfvar-create-buckets
CMD_BACKUP           := ./cmd/backup
CMD_CREATE           := ./cmd/create-buckets
INSTALL_DIR          := $(HOME)/.local/bin
VERSION_PKG          := github.com/mpechner/tfvar_backup/internal/version

GO                   := go
GOFLAGS              :=

# Injected at build time. 'make release' sets these from git; local builds get "dev".
VERSION  ?= dev
COMMIT   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE     ?= $(shell date -u +%Y-%m-%d)

LDFLAGS  := -s -w \
            -X $(VERSION_PKG).Version=$(VERSION) \
            -X $(VERSION_PKG).Commit=$(COMMIT) \
            -X $(VERSION_PKG).Date=$(DATE)

.PHONY: all build install clean fmt vet tidy

all: build

## build: compile both binaries into ./bin/
build:
	@mkdir -p bin
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/$(BINARY_BACKUP)  $(CMD_BACKUP)
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/$(BINARY_CREATE) $(CMD_CREATE)
	@echo "Built: bin/$(BINARY_BACKUP)  bin/$(BINARY_CREATE)"

## install: build and copy binaries to INSTALL_DIR (default: ~/.local/bin)
install: build
	@mkdir -p $(INSTALL_DIR)
	cp bin/$(BINARY_BACKUP)  $(INSTALL_DIR)/
	cp bin/$(BINARY_CREATE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)"

## clean: remove build artifacts
clean:
	rm -rf bin/

## fmt: run gofmt on all source files
fmt:
	$(GO) fmt ./...

## vet: run go vet
vet:
	$(GO) vet ./...

## tidy: tidy go.mod / go.sum
tidy:
	$(GO) mod tidy

## help: list available targets
help:
	@grep -E '^## ' Makefile | sed 's/## /  /'
