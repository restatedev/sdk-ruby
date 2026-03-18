.PHONY: tapioca typecheck lint lint-fix verify

# Generate Tapioca DSL RBI files (typed handler signatures)
tapioca:
	bundle exec tapioca dsl

# Type checking
typecheck:
	bundle exec srb tc

# Linting
lint:
	bundle exec rubocop

lint-fix:
	bundle exec rubocop -A

# Full verification: generate types, lint, typecheck
verify: tapioca lint typecheck
