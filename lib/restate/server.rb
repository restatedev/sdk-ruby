# frozen_string_literal: true

# Convenience entry point: `require "restate/server"` loads the core SDK
# plus the server module (Rack app + async execution context).
#
# Use this when you want both core and server loaded eagerly, e.g.:
#   gem "restate-sdk", require: "restate/server"
require_relative '../restate'
require_relative 'server/handler'
