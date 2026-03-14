# typed: false
# frozen_string_literal: true

# Rackup file for the greeter example.
#
# Run with:
#   cd examples && bundle exec falcon serve --bind http://localhost:9080

require_relative 'greeter'

run ENDPOINT.app
