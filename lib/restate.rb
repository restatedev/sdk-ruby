# typed: true
# frozen_string_literal: true

require 'sorbet-runtime'
require_relative 'restate/version'
require_relative 'restate/errors'
require_relative 'restate/serde'
require_relative 'restate/vm'
require_relative 'restate/context'
require_relative 'restate/handler'
require_relative 'restate/service_dsl'
require_relative 'restate/service'
require_relative 'restate/virtual_object'
require_relative 'restate/workflow'
require_relative 'restate/server_context'
require_relative 'restate/durable_future'
require_relative 'restate/discovery'
require_relative 'restate/endpoint'
require_relative 'restate/service_proxy'
require_relative 'restate/config'
require_relative 'restate/client'

# Restate Ruby SDK — build resilient applications with durable execution.
#
# All handler-facing operations are available as module methods on +Restate+.
# Inside a handler, call +Restate.run_sync+, +Restate.sleep+, +Restate.get+,
# etc. directly — no context parameter needed.
#
# The context is stored in +Thread.current[]+ (fiber-scoped in Ruby 3.0+).
# We intentionally use +Thread.current[]+ rather than +Fiber[]+ (Ruby 3.2+)
# because +Thread.current[]+ is NOT inherited by child fibers, which prevents
# accidental context leaks when Async spawns child tasks for run blocks.
module Restate # rubocop:disable Metrics/ModuleLength
  extend T::Sig

  module_function

  # Create an endpoint, optionally binding services.
  # Returns an Endpoint that can be further configured before calling +.app+.
  #
  # @param services [Array<Class>] service classes or instances to bind
  # @return [Endpoint]
  sig do
    params(
      services: T.untyped,
      protocol: T.nilable(String),
      identity_keys: T.nilable(T::Array[String])
    ).returns(Endpoint)
  end
  def endpoint(*services, protocol: nil, identity_keys: nil)
    ep = Endpoint.new
    ep.streaming_protocol if protocol == 'bidi'
    ep.request_response_protocol if protocol == 'request_response'
    services.each { |s| ep.bind(s) }
    identity_keys&.each { |k| ep.identity_key(k) }
    ep
  end

  # ── Global configuration ──

  # Configure the SDK globally. Settings are used by +Restate.client+.
  #
  # @example
  #   Restate.configure do |c|
  #     c.ingress_url = "http://localhost:8080"
  #     c.admin_url   = "http://localhost:9070"
  #   end
  sig { params(_block: T.proc.params(arg0: Config).void).void }
  def configure(&_block)
    yield config
  end

  # Returns the global configuration. Creates a default one on first access.
  sig { returns(Config) }
  def config
    @config = T.let(@config, T.nilable(Config)) unless defined?(@config)
    @config ||= Config.new
  end

  # Returns a pre-configured Client using the global +config+.
  # Creates a new Client on each call (stateless — safe to discard).
  #
  # @example
  #   Restate.client.service(Greeter).greet("World")
  #   Restate.client.resolve_awakeable(id, payload)
  #   Restate.client.create_deployment("http://localhost:9080")
  sig { returns(Client) }
  def client
    cfg = config
    Client.new(ingress_url: cfg.ingress_url, admin_url: cfg.admin_url,
               ingress_headers: cfg.ingress_headers, admin_headers: cfg.admin_headers)
  end

  # ── Context accessor (internal) ──

  # @!visibility private
  sig do
    params(service_kind: T.nilable(String), handler_kind: T.nilable(String)).returns(ServerContext)
  end
  def fetch_context!(service_kind: nil, handler_kind: nil) # rubocop:disable Metrics
    ctx = Thread.current[:restate_context]
    unless ctx
      Kernel.raise 'Not inside a Restate handler. ' \
                   'Restate.* methods can only be called during handler execution.'
    end

    if service_kind
      actual_service = Thread.current[:restate_service_kind]
      unless actual_service == service_kind
        Kernel.raise "Expected a #{service_kind} handler, but current handler is #{actual_service || 'unknown'}."
      end
    end

    if handler_kind
      actual_handler = Thread.current[:restate_handler_kind]
      unless actual_handler == handler_kind
        Kernel.raise "Expected a #{handler_kind} handler, but current handler kind is #{actual_handler || 'unknown'}."
      end
    end

    T.cast(ctx, ServerContext)
  end

  # ── Durable execution ──

  # Execute a durable side effect. The block runs at most once; the result
  # is journaled and replayed on retries. Returns a DurableFuture.
  sig do
    params(name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
           background: T::Boolean, action: T.proc.returns(T.untyped)).returns(DurableFuture)
  end
  def run(name, serde: JsonSerde, retry_policy: nil, background: false, &action)
    fetch_context!.run(name, serde: serde, retry_policy: retry_policy, background: background, &action)
  end

  # Convenience shortcut for +run(...).await+. Returns the result directly.
  sig do
    params(name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
           background: T::Boolean, action: T.proc.returns(T.untyped)).returns(T.untyped)
  end
  def run_sync(name, serde: JsonSerde, retry_policy: nil, background: false, &action)
    fetch_context!.run_sync(name, serde: serde, retry_policy: retry_policy, background: background, &action)
  end

  # Durable timer that survives handler restarts.
  sig { params(seconds: Numeric).returns(DurableFuture) }
  def sleep(seconds)
    fetch_context!.sleep(seconds)
  end

  # ── State operations (VirtualObject / Workflow) ──

  # Durably retrieve a state entry. Returns nil if unset.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def get(name, serde: JsonSerde)
    fetch_context!.get(name, serde: serde)
  end

  # Durably retrieve a state entry, returning a DurableFuture instead of blocking.
  sig { params(name: String, serde: T.untyped).returns(DurableFuture) }
  def get_async(name, serde: JsonSerde)
    fetch_context!.get_async(name, serde: serde)
  end

  # Durably set a state entry.
  sig { params(name: String, value: T.untyped, serde: T.untyped).void }
  def set(name, value, serde: JsonSerde)
    fetch_context!.set(name, value, serde: serde)
  end

  # Durably remove a single state entry.
  sig { params(name: String).void }
  def clear(name)
    fetch_context!.clear(name)
  end

  # Durably remove all state entries.
  sig { void }
  def clear_all
    fetch_context!.clear_all
  end

  # List all state entry names.
  sig { returns(T.untyped) }
  def state_keys
    fetch_context!.state_keys
  end

  # List all state entry names, returning a DurableFuture.
  sig { returns(DurableFuture) }
  def state_keys_async
    fetch_context!.state_keys_async
  end

  # ── Service communication ──

  # Durably call a handler on a Restate service.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           arg: T.untyped, key: T.nilable(String), idempotency_key: T.nilable(String),
           headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped, output_serde: T.untyped).returns(DurableCallFuture)
  end
  def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                   input_serde: NOT_SET, output_serde: NOT_SET)
    ctx = fetch_context!
    ctx.service_call(service, handler, arg, key: key, idempotency_key: idempotency_key,
                                            headers: headers, input_serde: input_serde, output_serde: output_serde)
  end

  # Fire-and-forget send to a Restate service handler.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           arg: T.untyped, key: T.nilable(String), delay: T.nilable(Numeric),
           idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped).returns(SendHandle)
  end
  def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil,
                   headers: nil, input_serde: NOT_SET)
    ctx = fetch_context!
    ctx.service_send(service, handler, arg, key: key, delay: delay, idempotency_key: idempotency_key,
                                            headers: headers, input_serde: input_serde)
  end

  # Durably call a handler on a Restate virtual object.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           key: String, arg: T.untyped, idempotency_key: T.nilable(String),
           headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped, output_serde: T.untyped).returns(DurableCallFuture)
  end
  def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                  input_serde: NOT_SET, output_serde: NOT_SET)
    ctx = fetch_context!
    ctx.object_call(service, handler, key, arg, idempotency_key: idempotency_key,
                                                headers: headers, input_serde: input_serde, output_serde: output_serde)
  end

  # Fire-and-forget send to a Restate virtual object handler.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           key: String, arg: T.untyped, delay: T.nilable(Numeric),
           idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped).returns(SendHandle)
  end
  def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                  headers: nil, input_serde: NOT_SET)
    ctx = fetch_context!
    ctx.object_send(service, handler, key, arg, delay: delay, idempotency_key: idempotency_key,
                                                headers: headers, input_serde: input_serde)
  end

  # Durably call a handler on a Restate workflow.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           key: String, arg: T.untyped, idempotency_key: T.nilable(String),
           headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped, output_serde: T.untyped).returns(DurableCallFuture)
  end
  def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: NOT_SET, output_serde: NOT_SET)
    ctx = fetch_context!
    ctx.workflow_call(service, handler, key, arg,
                      idempotency_key: idempotency_key, headers: headers,
                      input_serde: input_serde, output_serde: output_serde)
  end

  # Fire-and-forget send to a Restate workflow handler.
  sig do
    params(service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
           key: String, arg: T.untyped, delay: T.nilable(Numeric),
           idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
           input_serde: T.untyped).returns(SendHandle)
  end
  def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                    headers: nil, input_serde: NOT_SET)
    ctx = fetch_context!
    ctx.workflow_send(service, handler, key, arg, delay: delay, idempotency_key: idempotency_key,
                                                  headers: headers, input_serde: input_serde)
  end

  # Durably call a handler using raw bytes (no serialization).
  sig do
    params(service: String, handler: String, arg: String,
           key: T.nilable(String), idempotency_key: T.nilable(String),
           headers: T.nilable(T::Hash[String, String])).returns(DurableCallFuture)
  end
  def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil)
    fetch_context!.generic_call(service, handler, arg, key: key,
                                                       idempotency_key: idempotency_key, headers: headers)
  end

  # Fire-and-forget send using raw bytes (no serialization).
  sig do
    params(service: String, handler: String, arg: String,
           key: T.nilable(String), delay: T.nilable(Numeric),
           idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String])).returns(SendHandle)
  end
  def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil)
    fetch_context!.generic_send(service, handler, arg, key: key, delay: delay,
                                                       idempotency_key: idempotency_key, headers: headers)
  end

  # ── Awakeables ──

  # Create an awakeable for external callbacks. Returns [awakeable_id, DurableFuture].
  sig { params(serde: T.untyped).returns([String, DurableFuture]) }
  def awakeable(serde: JsonSerde)
    fetch_context!.awakeable(serde: serde)
  end

  # Resolve an awakeable with a success value.
  sig { params(awakeable_id: String, payload: T.untyped, serde: T.untyped).void }
  def resolve_awakeable(awakeable_id, payload, serde: JsonSerde)
    fetch_context!.resolve_awakeable(awakeable_id, payload, serde: serde)
  end

  # Reject an awakeable with a terminal failure.
  sig { params(awakeable_id: String, message: String, code: Integer).void }
  def reject_awakeable(awakeable_id, message, code: 500)
    fetch_context!.reject_awakeable(awakeable_id, message, code: code)
  end

  # ── Promises (Workflow only) ──

  # Get a durable promise value, blocking until resolved.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def promise(name, serde: JsonSerde)
    fetch_context!.promise(name, serde: serde)
  end

  # Peek at a durable promise without blocking. Returns nil if not yet resolved.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def peek_promise(name, serde: JsonSerde)
    fetch_context!.peek_promise(name, serde: serde)
  end

  # Resolve a durable promise with a value.
  sig { params(name: String, payload: T.untyped, serde: T.untyped).void }
  def resolve_promise(name, payload, serde: JsonSerde)
    fetch_context!.resolve_promise(name, payload, serde: serde)
  end

  # Reject a durable promise with a terminal failure.
  sig { params(name: String, message: String, code: Integer).void }
  def reject_promise(name, message, code: 500)
    fetch_context!.reject_promise(name, message, code: code)
  end

  # ── Futures ──

  # Wait until any of the given futures completes. Returns [completed, remaining].
  sig { params(futures: T::Array[DurableFuture]).returns([T::Array[DurableFuture], T::Array[DurableFuture]]) }
  def wait_any(*futures)
    T.unsafe(fetch_context!).wait_any(*futures)
  end

  # ── Request metadata ──

  # Returns metadata about the current invocation (id, headers, raw body).
  sig { returns(T.untyped) }
  def request
    fetch_context!.request
  end

  # Returns the key for this virtual object or workflow invocation.
  sig { returns(String) }
  def key
    fetch_context!.key
  end

  # ── Invocation control ──

  # Request cancellation of another invocation.
  sig { params(invocation_id: String).void }
  def cancel_invocation(invocation_id)
    fetch_context!.cancel_invocation(invocation_id)
  end
end
