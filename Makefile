.PHONY: build compile test test-harness test-integration clean fmt check install typecheck lint lint-fix verify tapioca

# Build the native extension and compile
build: compile

compile:
	bundle exec rake compile

# Run unit tests
test: compile
	bundle exec rake spec

# Run test harness specs (requires Docker)
test-harness: compile
	bundle exec rspec spec/harness_spec.rb

# Run sdk-test-suite integration tests (requires Docker + Java 21+)
test-integration: compile
	./etc/run-integration-tests.sh

# Generate Tapioca DSL RBI files (typed handler signatures)
tapioca: compile
	bundle exec tapioca dsl

# Type checking
typecheck:
	bundle exec srb tc

# Linting
lint:
	bundle exec rubocop

lint-fix:
	bundle exec rubocop -A

# Check Rust code compiles
check:
	cargo check

# Format Rust code
fmt:
	cargo fmt

# Clean build artifacts
clean:
	cargo clean
	rm -rf tmp/ pkg/ lib/restate/restate_internal.*

# Install gem dependencies
install:
	bundle install

# Build the gem
gem: compile
	gem build restate-sdk.gemspec

# Build, lint, typecheck, and run unit tests (no integration tests)
verify: compile tapioca lint typecheck test-harness

# Run everything (install, compile, test, typecheck, lint)
all: install compile test typecheck lint
