.PHONY: build compile test clean fmt check install typecheck lint lint-fix

# Build the native extension and compile
build: compile

compile:
	bundle exec rake compile

# Run tests
test: compile
	bundle exec rake spec

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

# Run everything (install, compile, test, typecheck, lint)
all: install compile test typecheck lint
