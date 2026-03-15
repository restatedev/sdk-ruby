# typed: false
# frozen_string_literal: true

# Serves all example services on a single endpoint.
#
# Run with:
#   cd examples && bundle exec falcon serve --bind http://localhost:9080
#
# Register with Restate:
#   restate deployments register http://localhost:9080

require_relative 'greeter'
require_relative 'durable_execution'
require_relative 'virtual_objects'
require_relative 'workflow'
require_relative 'service_communication'
require_relative 'typed_handlers'

endpoint = Restate.endpoint(
  Greeter,
  SubscriptionService,
  Counter,
  UserSignup,
  Worker, FanOut,
  TicketService
)

run endpoint.app
