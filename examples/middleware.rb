# typed: true
# frozen_string_literal: true

#
# Example: Handler Middleware
#
# Middleware wraps every handler invocation — like Sidekiq middleware.
# Use it for tracing, metrics, logging, error reporting, tenant isolation, etc.
#
# Each middleware is a class with a `call(handler, ctx)` method that uses
# `yield` to invoke the next middleware or the handler itself. Constructor
# args are passed via `endpoint.use(Klass, args...)`.
#
# Available in `call`:
#   handler.name                — handler method name ("greet")
#   handler.service_tag.name    — service name ("Greeter")
#   handler.service_tag.kind    — "service", "object", or "workflow"
#   handler.kind                — nil, "exclusive", "shared", or "workflow"
#   ctx.request.id              — invocation ID
#   ctx.request.headers         — invocation headers (durable, from caller)
#
# Try it:
#   curl localhost:8080/MiddlewareDemo/greet \
#     -H 'content-type: application/json' \
#     -H 'x-team-id: acme-corp' \
#     -d '"World"'

require 'restate'

# ── Logging middleware ──
# Logs every handler invocation with timing.
class LoggingMiddleware
  # @param handler [Restate::Handler]
  # @param ctx [Restate::Context]
  def call(handler, ctx) # rubocop:disable Metrics/AbcSize
    service = handler.service_tag.name
    name = handler.name
    invocation_id = ctx.request.id
    puts "[#{service}/#{name}] Starting (invocation: #{invocation_id})"
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts "[#{service}/#{name}] Completed in #{(duration * 1000).round(1)}ms"
    result
  rescue StandardError => e
    puts "[#{service}/#{name}] Failed: #{e.class} — #{e.message}"
    raise
  end
end

# ── Tenant context middleware ──
# Extracts team_id from invocation headers and stores it in fiber-local storage.
# Downstream code can read Thread.current[:team_id] for tenant isolation.
class TenantMiddleware
  # @param handler [Restate::Handler]
  # @param ctx [Restate::Context]
  def call(_handler, ctx)
    Thread.current[:team_id] = ctx.request.headers['x-team-id']
    yield
  ensure
    Thread.current[:team_id] = nil
  end
end

# ── Metrics middleware (with constructor args) ──
# Demonstrates middleware with configuration. In production you'd use
# a real Prometheus client or StatsD.
class MetricsMiddleware
  def initialize(prefix: 'restate')
    @prefix = prefix
    @counts = Hash.new(0)
  end

  # @param handler [Restate::Handler]
  # @param _ctx [Restate::Context]
  def call(handler, _ctx)
    key = "#{@prefix}.#{handler.service_tag.name}.#{handler.name}"
    @counts[key] += 1
    yield
  end

  def counts
    @counts.dup
  end
end

# ── Service ──

class MiddlewareDemo < Restate::Service
  handler :greet, input: String, output: String
  # @param ctx [Restate::Context]
  # @param name [String]
  # @return [String]
  def greet(ctx, name)
    team = Thread.current[:team_id] || 'unknown'
    ctx.run_sync('build-greeting') { "Hello, #{name}! (team: #{team})" }
  end
end
