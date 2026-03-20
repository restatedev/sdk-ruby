# typed: true

# RBI shipped with the restate-sdk gem.
# Tapioca merges this automatically when users run `tapioca gems`.

module Restate
  # Create an endpoint, optionally binding services.
  sig do
    params(
      services: T.untyped,
      protocol: T.nilable(String),
      identity_keys: T.nilable(T::Array[String])
    ).returns(Restate::Endpoint)
  end
  def self.endpoint(*services, protocol: nil, identity_keys: nil); end

  # ── Durable execution ──

  # Execute a durable side effect. Returns a DurableFuture.
  sig do
    params(
      name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
      background: T::Boolean, action: T.proc.returns(T.untyped)
    ).returns(DurableFuture)
  end
  def self.run(name, serde: Restate::JsonSerde, retry_policy: nil, background: false, &action); end

  # Convenience shortcut for +run(...).await+. Returns the result directly.
  sig do
    params(
      name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
      background: T::Boolean, action: T.proc.returns(T.untyped)
    ).returns(T.untyped)
  end
  def self.run_sync(name, serde: Restate::JsonSerde, retry_policy: nil, background: false, &action); end

  # Durable timer that survives handler restarts.
  sig { params(seconds: Numeric).returns(DurableFuture) }
  def self.sleep(seconds); end

  # ── State operations (VirtualObject / Workflow) ──

  # Durably retrieve a state entry. Returns nil if unset.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def self.get(name, serde: Restate::JsonSerde); end

  # Durably retrieve a state entry, returning a DurableFuture instead of blocking.
  sig { params(name: String, serde: T.untyped).returns(DurableFuture) }
  def self.get_async(name, serde: Restate::JsonSerde); end

  # Durably set a state entry.
  sig { params(name: String, value: T.untyped, serde: T.untyped).void }
  def self.set(name, value, serde: Restate::JsonSerde); end

  # Durably remove a single state entry.
  sig { params(name: String).void }
  def self.clear(name); end

  # Durably remove all state entries.
  sig { void }
  def self.clear_all; end

  # List all state entry names.
  sig { returns(T.untyped) }
  def self.state_keys; end

  # List all state entry names, returning a DurableFuture.
  sig { returns(DurableFuture) }
  def self.state_keys_async; end

  # ── Service communication ──

  # Durably call a handler on a Restate service.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      arg: T.untyped, key: T.nilable(String), idempotency_key: T.nilable(String),
      headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
    ).returns(DurableCallFuture)
  end
  def self.service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                        input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

  # Fire-and-forget send to a Restate service handler.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      arg: T.untyped, key: T.nilable(String), delay: T.nilable(Numeric),
      idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
      input_serde: T.untyped
    ).returns(SendHandle)
  end
  def self.service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil,
                        headers: nil, input_serde: T.unsafe(nil)); end

  # Durably call a handler on a Restate virtual object.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      key: String, arg: T.untyped, idempotency_key: T.nilable(String),
      headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
    ).returns(DurableCallFuture)
  end
  def self.object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                       input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

  # Fire-and-forget send to a Restate virtual object handler.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      key: String, arg: T.untyped, delay: T.nilable(Numeric),
      idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
      input_serde: T.untyped
    ).returns(SendHandle)
  end
  def self.object_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                       headers: nil, input_serde: T.unsafe(nil)); end

  # Durably call a handler on a Restate workflow.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      key: String, arg: T.untyped, idempotency_key: T.nilable(String),
      headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
    ).returns(DurableCallFuture)
  end
  def self.workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                         input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

  # Fire-and-forget send to a Restate workflow handler.
  sig do
    params(
      service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
      key: String, arg: T.untyped, delay: T.nilable(Numeric),
      idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
      input_serde: T.untyped
    ).returns(SendHandle)
  end
  def self.workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                         headers: nil, input_serde: T.unsafe(nil)); end

  # Durably call a handler using raw bytes (no serialization).
  sig do
    params(
      service: String, handler: String, arg: String,
      key: T.nilable(String), idempotency_key: T.nilable(String),
      headers: T.nilable(T::Hash[String, String])
    ).returns(DurableCallFuture)
  end
  def self.generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil); end

  # Fire-and-forget send using raw bytes (no serialization).
  sig do
    params(
      service: String, handler: String, arg: String,
      key: T.nilable(String), delay: T.nilable(Numeric),
      idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String])
    ).returns(SendHandle)
  end
  def self.generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil); end

  # ── Awakeables ──

  # Create an awakeable for external callbacks. Returns [awakeable_id, DurableFuture].
  sig { params(serde: T.untyped).returns([String, DurableFuture]) }
  def self.awakeable(serde: Restate::JsonSerde); end

  # Resolve an awakeable with a success value.
  sig { params(awakeable_id: String, payload: T.untyped, serde: T.untyped).void }
  def self.resolve_awakeable(awakeable_id, payload, serde: Restate::JsonSerde); end

  # Reject an awakeable with a terminal failure.
  sig { params(awakeable_id: String, message: String, code: Integer).void }
  def self.reject_awakeable(awakeable_id, message, code: 500); end

  # ── Promises (Workflow only) ──

  # Get a durable promise value, blocking until resolved.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def self.promise(name, serde: Restate::JsonSerde); end

  # Peek at a durable promise without blocking. Returns nil if not yet resolved.
  sig { params(name: String, serde: T.untyped).returns(T.untyped) }
  def self.peek_promise(name, serde: Restate::JsonSerde); end

  # Resolve a durable promise with a value.
  sig { params(name: String, payload: T.untyped, serde: T.untyped).void }
  def self.resolve_promise(name, payload, serde: Restate::JsonSerde); end

  # Reject a durable promise with a terminal failure.
  sig { params(name: String, message: String, code: Integer).void }
  def self.reject_promise(name, message, code: 500); end

  # ── Futures ──

  # Wait until any of the given futures completes. Returns [completed, remaining].
  sig { params(futures: DurableFuture).returns([T::Array[DurableFuture], T::Array[DurableFuture]]) }
  def self.wait_any(*futures); end

  # ── Request metadata ──

  # Returns metadata about the current invocation (id, headers, raw body).
  sig { returns(T.untyped) }
  def self.request; end

  # Returns the key for this virtual object or workflow invocation.
  sig { returns(String) }
  def self.key; end

  # ── Invocation control ──

  # Request cancellation of another invocation.
  sig { params(invocation_id: String).void }
  def self.cancel_invocation(invocation_id); end

  class TerminalError < StandardError
    sig { returns(Integer) }
    def status_code; end

    sig { params(message: String, status_code: Integer).void }
    def initialize(message = '', status_code: 500); end
  end

  class AttemptFinishedEvent
    sig { returns(T::Boolean) }
    def set?; end

    sig { void }
    def wait; end
  end

  Request = T.type_alias { T.untyped }

  class RunRetryPolicy < T::Struct
    const :initial_interval, T.nilable(Integer)
    const :max_attempts, T.nilable(Integer)
    const :max_duration, T.nilable(Integer)
    const :max_interval, T.nilable(Integer)
    const :interval_factor, T.nilable(Float)
  end

  class DurableFuture
    sig { returns(T.untyped) }
    def await; end

    sig { returns(T::Boolean) }
    def completed?; end

    sig { returns(Integer) }
    def handle; end
  end

  class DurableCallFuture < DurableFuture
    sig { returns(String) }
    def invocation_id; end

    sig { void }
    def cancel; end
  end

  class SendHandle
    sig { returns(String) }
    def invocation_id; end

    sig { void }
    def cancel; end
  end

  # Base context interface for all Restate handlers.
  module Context
    sig do
      params(
        name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
        background: T::Boolean, action: T.proc.returns(T.untyped)
      ).returns(DurableFuture)
    end
    def run(name, serde: Restate::JsonSerde, retry_policy: nil, background: false, &action); end

    sig do
      params(
        name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
        background: T::Boolean, action: T.proc.returns(T.untyped)
      ).returns(T.untyped)
    end
    def run_sync(name, serde: Restate::JsonSerde, retry_policy: nil, background: false, &action); end

    sig { params(seconds: Numeric).returns(DurableFuture) }
    def sleep(seconds); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        arg: T.untyped, key: T.nilable(String), idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        arg: T.untyped, key: T.nilable(String), delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil,
                     headers: nil, input_serde: T.unsafe(nil)); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                    headers: nil, input_serde: T.unsafe(nil)); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                      input_serde: T.unsafe(nil), output_serde: T.unsafe(nil)); end

    sig do
      params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                      headers: nil, input_serde: T.unsafe(nil)); end

    sig do
      params(
        service: String, handler: String, arg: String,
        key: T.nilable(String), idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(DurableCallFuture)
    end
    def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil); end

    sig do
      params(
        service: String, handler: String, arg: String,
        key: T.nilable(String), delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String])
      ).returns(SendHandle)
    end
    def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil); end

    sig { params(serde: T.untyped).returns([String, DurableFuture]) }
    def awakeable(serde: Restate::JsonSerde); end

    sig { params(awakeable_id: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_awakeable(awakeable_id, payload, serde: Restate::JsonSerde); end

    sig { params(awakeable_id: String, message: String, code: Integer).void }
    def reject_awakeable(awakeable_id, message, code: 500); end

    sig { params(invocation_id: String).void }
    def cancel_invocation(invocation_id); end

    sig { params(futures: DurableFuture).returns([T::Array[DurableFuture], T::Array[DurableFuture]]) }
    def wait_any(*futures); end

    sig { returns(T.untyped) }
    def request; end

    sig { returns(String) }
    def key; end
  end

  # VirtualObject shared handler context (read-only state).
  module ObjectSharedContext
    include Context

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def get(name, serde: Restate::JsonSerde); end

    sig { params(name: String, serde: T.untyped).returns(DurableFuture) }
    def get_async(name, serde: Restate::JsonSerde); end

    sig { returns(T.untyped) }
    def state_keys; end

    sig { returns(DurableFuture) }
    def state_keys_async; end
  end

  # VirtualObject exclusive handler context (full state access).
  module ObjectContext
    include ObjectSharedContext

    sig { params(name: String, value: T.untyped, serde: T.untyped).void }
    def set(name, value, serde: Restate::JsonSerde); end

    sig { params(name: String).void }
    def clear(name); end

    sig { void }
    def clear_all; end
  end

  # Workflow shared handler context (read-only state + promises).
  module WorkflowSharedContext
    include ObjectSharedContext

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def promise(name, serde: Restate::JsonSerde); end

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def peek_promise(name, serde: Restate::JsonSerde); end

    sig { params(name: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_promise(name, payload, serde: Restate::JsonSerde); end

    sig { params(name: String, message: String, code: Integer).void }
    def reject_promise(name, message, code: 500); end
  end

  # Workflow main handler context (full state + promises).
  module WorkflowContext
    include ObjectContext

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def promise(name, serde: Restate::JsonSerde); end

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def peek_promise(name, serde: Restate::JsonSerde); end

    sig { params(name: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_promise(name, payload, serde: Restate::JsonSerde); end

    sig { params(name: String, message: String, code: Integer).void }
    def reject_promise(name, message, code: 500); end
  end

  # Stateless service base class.
  class Service
    sig { returns(ServiceCallProxy) }
    def self.call; end

    sig { params(delay: T.nilable(Numeric)).returns(ServiceSendProxy) }
    def self.send!(delay: nil); end
  end

  # Keyed virtual object base class.
  class VirtualObject
    sig { params(key: String).returns(ServiceCallProxy) }
    def self.call(key); end

    sig { params(key: String, delay: T.nilable(Numeric)).returns(ServiceSendProxy) }
    def self.send!(key, delay: nil); end

    sig { params(name: Symbol, default: T.untyped, serde: T.untyped).void }
    def self.state(name, default: nil, serde: nil); end
  end

  # Durable workflow base class.
  class Workflow
    sig { params(key: String).returns(ServiceCallProxy) }
    def self.call(key); end

    sig { params(key: String, delay: T.nilable(Numeric)).returns(ServiceSendProxy) }
    def self.send!(key, delay: nil); end

    sig { params(name: Symbol, default: T.untyped, serde: T.untyped).void }
    def self.state(name, default: nil, serde: nil); end
  end

  # Proxy for fluent durable calls.
  class ServiceCallProxy; end

  # Proxy for fluent fire-and-forget sends.
  class ServiceSendProxy; end

  # Global SDK configuration.
  class Config
    sig { returns(String) }
    attr_accessor :ingress_url

    sig { returns(String) }
    attr_accessor :admin_url

    sig { returns(T::Hash[String, String]) }
    attr_accessor :ingress_headers

    sig { returns(T::Hash[String, String]) }
    attr_accessor :admin_headers
  end

  # Configure the SDK globally.
  sig { params(block: T.proc.params(arg0: Config).void).void }
  def self.configure(&block); end

  # Returns the global configuration.
  sig { returns(Config) }
  def self.config; end

  # Returns a pre-configured Client using the global config.
  sig { returns(Client) }
  def self.client; end

  # HTTP client for invoking Restate services and managing the runtime.
  class Client
    sig do
      params(ingress_url: String, admin_url: String,
             ingress_headers: T::Hash[String, String],
             admin_headers: T::Hash[String, String]).void
    end
    def initialize(ingress_url: 'http://localhost:8080', admin_url: 'http://localhost:9070',
                   ingress_headers: {}, admin_headers: {}); end

    sig { params(service: T.any(String, T::Class[T.anything])).returns(ClientServiceProxy) }
    def service(service); end

    sig { params(service: T.any(String, T::Class[T.anything]), key: String).returns(ClientServiceProxy) }
    def object(service, key); end

    sig { params(service: T.any(String, T::Class[T.anything]), key: String).returns(ClientServiceProxy) }
    def workflow(service, key); end

    sig { params(awakeable_id: String, payload: T.untyped).void }
    def resolve_awakeable(awakeable_id, payload); end

    sig { params(awakeable_id: String, message: String, code: Integer).void }
    def reject_awakeable(awakeable_id, message, code: 500); end

    sig { params(invocation_id: String).void }
    def cancel_invocation(invocation_id); end

    sig { params(invocation_id: String).void }
    def kill_invocation(invocation_id); end

  end

  # Proxy for HTTP client calls.
  class ClientServiceProxy; end

  class Endpoint
    sig { params(services: T.untyped).void }
    def bind(*services); end

    sig { void }
    def streaming_protocol; end

    sig { void }
    def request_response_protocol; end

    sig { params(key: String).void }
    def identity_key(key); end

    sig { params(klass: T.untyped, args: T.untyped, kwargs: T.untyped).returns(T.self_type) }
    def use(klass, *args, **kwargs); end

    sig { returns(T.untyped) }
    def app; end
  end

  module JsonSerde; end
  module BytesSerde; end
end
