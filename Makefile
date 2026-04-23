.PHONY: help docs docs-hex docs-book docs-serve clean test test-unit test-integration test-security fmt-check compile-check credo dialyzer test-all ci

help: ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

docs: docs-hex docs-book ## Build all documentation (HexDocs + mdBook)

docs-hex: ## Build HexDocs API reference
	@echo "Building HexDocs..."
	@mix docs
	@echo "✓ HexDocs built to doc/"

docs-book: ## Build mdBook usage guide
	@echo "Building mdBook..."
	@command -v mdbook >/dev/null 2>&1 || { echo "Error: mdbook not found. Install from https://rust-lang.github.io/mdBook/"; exit 1; }
	@mdbook build
	@echo "✓ mdBook built to doc/book/"

docs-serve: ## Serve mdBook with live reload
	@command -v mdbook >/dev/null 2>&1 || { echo "Error: mdbook not found. Install from https://rust-lang.github.io/mdBook/"; exit 1; }
	@mdbook serve

docs-open: docs ## Build and open documentation in browser
	@open doc/index.html || xdg-open doc/index.html || echo "Open doc/index.html in your browser"
	@open doc/book/index.html || xdg-open doc/book/index.html || echo "Open doc/book/index.html in your browser"

clean: ## Clean generated documentation
	@echo "Cleaning documentation..."
	@rm -rf doc/
	@echo "✓ Documentation cleaned"

test: test-unit  ## Run unit tests (alias for backward compat)

test-all: ## Run ALL tests (unit + integration + security) in one ExUnit run
	@mix test --include integration --include security

fmt-check: ## Check code formatting
	@mix format --check-formatted

compile-check: ## Compile with warnings-as-errors
	@mix compile --warnings-as-errors

test-unit: ## Run unit tests only (excludes integration + security)
	@mix test

test-integration: ## Run integration tests only
	@mix test --only integration

test-security: ## Run security tests only (test/security/ + inline @tag :security)
	@mix test --only security

credo: ## Run Credo static analysis (strict mode)
	@mix credo --strict

dialyzer: ## Run Dialyzer type checking
	@mix dialyzer

ci: ## Run full CI suite locally (sequential, fail-fast)
	$(MAKE) fmt-check compile-check test-unit test-integration test-security credo dialyzer

.DEFAULT_GOAL := help
