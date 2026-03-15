# typed: true
# frozen_string_literal: true

# rubocop:disable Metrics/ModuleLength,Metrics/ParameterLists,Style/EmptyMethod
module Restate
  # Signals when the current invocation attempt has finished — either the handler
  # completed, the connection was lost, or a transient error occurred.
  #
  # Use this to clean up attempt-scoped resources (open connections, temp files,
  # etc.) that should not outlive the current attempt.
  #
  # Available via +ctx.request.attempt_finished_event+.
  #
  # @example Cancel a long-running HTTP call when the attempt finishes
  #   event = ctx.request.attempt_finished_event
  #   ctx.run('call-api') do
  #     # poll event.set? periodically, or pass it to your HTTP client
  #   end
  class AttemptFinishedEvent
    extend T::Sig

    sig { void }
    def initialize
      @mutex = T.let(Mutex.new, Mutex)
      @set = T.let(false, T::Boolean)
      @waiters = T.let([], T::Array[Thread::Queue])
    end

    # Returns true if the attempt has finished.
    sig { returns(T::Boolean) }
    def set?
      @set
    end

    # Blocks the current fiber/thread until the attempt finishes.
    sig { void }
    def wait
      return if @set

      waiter = T.let(nil, T.nilable(Thread::Queue))
      @mutex.synchronize do
        unless @set
          waiter = Thread::Queue.new
          @waiters << waiter
        end
      end
      waiter&.pop
    end

    # Marks the event as set and wakes all waiters.
    # Called internally by the SDK when the attempt ends.
    sig { void }
    def set!
      @mutex.synchronize do
        @set = true
        @waiters.each { |w| w.push(true) }
        @waiters.clear
      end
    end
  end

  # Request metadata available to handlers via +ctx.request+.
  #
  # @!attribute [r] id
  #   @return [String] the invocation ID
  # @!attribute [r] headers
  #   @return [Hash{String => String}] request headers
  # @!attribute [r] body
  #   @return [String] raw input bytes
  # @!attribute [r] attempt_finished_event
  #   @return [AttemptFinishedEvent] signaled when this attempt ends
  Request = Struct.new(:id, :headers, :body, :attempt_finished_event, keyword_init: true)

  # Base context interface for all Restate handlers.
  #
  # Provides durable execution (+run+, +run_sync+), timers (+sleep+),
  # service-to-service calls, awakeables, and request metadata.
  #
  # @see ObjectContext for VirtualObject handlers (adds state operations)
  # @see WorkflowContext for Workflow handlers (adds promise operations)
  module Context
    extend T::Sig
    extend T::Helpers

    abstract!

    # Execute a durable side effect. The block runs at most once; the result
    # is journaled and replayed on retries.
    #
    # Pass +background: true+ to offload the block to a real OS Thread,
    # keeping the fiber event loop responsive for CPU-intensive work.
    sig do
      abstract.params(
        name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
        background: T::Boolean, action: T.proc.returns(T.untyped)
      ).returns(DurableFuture)
    end
    def run(name, serde: JsonSerde, retry_policy: nil, background: false, &action); end

    # Convenience shortcut for +run(...).await+. Returns the result directly.
    # Accepts all the same options as +run+, including +background: true+.
    sig do
      abstract.params(
        name: String, serde: T.untyped, retry_policy: T.nilable(RunRetryPolicy),
        background: T::Boolean, action: T.proc.returns(T.untyped)
      ).returns(T.untyped)
    end
    def run_sync(name, serde: JsonSerde, retry_policy: nil, background: false, &action); end

    # Durable timer that survives handler restarts.
    sig { params(seconds: Numeric).returns(DurableFuture) }
    def sleep(seconds) # rubocop:disable Lint/UnusedMethodArgument
      Kernel.raise NotImplementedError
    end

    # Durably call a handler on a Restate service.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        arg: T.untyped, key: T.nilable(String), idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     input_serde: NOT_SET, output_serde: NOT_SET)
    end
    # Fire-and-forget send to a Restate service handler.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        arg: T.untyped, key: T.nilable(String), delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil,
                     headers: nil, input_serde: NOT_SET)
    end
    # Durably call a handler on a Restate virtual object.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: NOT_SET, output_serde: NOT_SET)
    end
    # Fire-and-forget send to a Restate virtual object handler.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                    headers: nil, input_serde: NOT_SET)
    end
    # Durably call a handler on a Restate workflow.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]), input_serde: T.untyped, output_serde: T.untyped
      ).returns(DurableCallFuture)
    end
    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                      input_serde: NOT_SET, output_serde: NOT_SET)
    end
    # Fire-and-forget send to a Restate workflow handler.
    sig do
      abstract.params(
        service: T.any(String, T::Class[T.anything]), handler: T.any(String, Symbol),
        key: String, arg: T.untyped, delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).returns(SendHandle)
    end
    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                      headers: nil, input_serde: NOT_SET)
    end
    # Durably call a handler using raw bytes (no serialization).
    sig do
      abstract.params(
        service: String, handler: String, arg: String,
        key: T.nilable(String), idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(DurableCallFuture)
    end
    def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil); end

    # Fire-and-forget send using raw bytes (no serialization).
    sig do
      abstract.params(
        service: String, handler: String, arg: String,
        key: T.nilable(String), delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String), headers: T.nilable(T::Hash[String, String])
      ).returns(SendHandle)
    end
    def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil); end

    # Create an awakeable for external callbacks.
    # Returns [awakeable_id, DurableFuture].
    sig { abstract.params(serde: T.untyped).returns([String, DurableFuture]) }
    def awakeable(serde: JsonSerde); end

    # Resolve an awakeable with a success value.
    sig { abstract.params(awakeable_id: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_awakeable(awakeable_id, payload, serde: JsonSerde); end

    # Reject an awakeable with a terminal failure.
    sig { abstract.params(awakeable_id: String, message: String, code: Integer).void }
    def reject_awakeable(awakeable_id, message, code: 500); end

    # Request cancellation of another invocation.
    sig { abstract.params(invocation_id: String).void }
    def cancel_invocation(invocation_id); end

    # Wait until any of the given futures completes.
    # Returns [completed, remaining].
    sig { abstract.params(futures: DurableFuture).returns([T::Array[DurableFuture], T::Array[DurableFuture]]) }
    def wait_any(*futures); end

    # Returns metadata about the current invocation.
    sig { abstract.returns(Request) }
    def request; end

    # Returns the key for this virtual object or workflow invocation.
    sig { abstract.returns(String) }
    def key; end
  end

  # Context interface for VirtualObject shared handlers (read-only state).
  # Extends {Context} with +get+, +state_keys+, and +key+ — but no mutations.
  module ObjectSharedContext
    extend T::Sig
    extend T::Helpers

    abstract!
    include Context

    # Durably retrieve a state entry. Returns nil if unset.
    sig { abstract.params(name: String, serde: T.untyped).returns(T.untyped) }
    def get(name, serde: JsonSerde); end

    # List all state entry names.
    sig { abstract.returns(T.untyped) }
    def state_keys; end
  end

  # Context interface for VirtualObject exclusive handlers (full state access).
  # Extends {ObjectSharedContext} with mutating state operations.
  module ObjectContext
    extend T::Sig
    extend T::Helpers

    abstract!
    include ObjectSharedContext

    # Durably set a state entry.
    sig { abstract.params(name: String, value: T.untyped, serde: T.untyped).void }
    def set(name, value, serde: JsonSerde); end

    # Durably remove a single state entry.
    sig { abstract.params(name: String).void }
    def clear(name); end

    # Durably remove all state entries.
    sig { abstract.void }
    def clear_all; end
  end

  # Context interface for Workflow shared handlers (read-only state + promises).
  # Extends {ObjectSharedContext} with durable promise operations.
  module WorkflowSharedContext
    extend T::Sig
    extend T::Helpers

    abstract!
    include ObjectSharedContext

    # Get a durable promise value, blocking until resolved.
    sig { abstract.params(name: String, serde: T.untyped).returns(T.untyped) }
    def promise(name, serde: JsonSerde); end

    # Peek at a durable promise without blocking. Returns nil if not yet resolved.
    sig { abstract.params(name: String, serde: T.untyped).returns(T.untyped) }
    def peek_promise(name, serde: JsonSerde); end

    # Resolve a durable promise with a value.
    sig { abstract.params(name: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_promise(name, payload, serde: JsonSerde); end

    # Reject a durable promise with a terminal failure.
    sig { abstract.params(name: String, message: String, code: Integer).void }
    def reject_promise(name, message, code: 500); end
  end

  # Context interface for Workflow main handler (full state + promises).
  # Extends {ObjectContext} with durable promise operations.
  module WorkflowContext
    extend T::Sig
    extend T::Helpers

    abstract!
    include ObjectContext

    # Get a durable promise value, blocking until resolved.
    sig { abstract.params(name: String, serde: T.untyped).returns(T.untyped) }
    def promise(name, serde: JsonSerde); end

    # Peek at a durable promise without blocking. Returns nil if not yet resolved.
    sig { abstract.params(name: String, serde: T.untyped).returns(T.untyped) }
    def peek_promise(name, serde: JsonSerde); end

    # Resolve a durable promise with a value.
    sig { abstract.params(name: String, payload: T.untyped, serde: T.untyped).void }
    def resolve_promise(name, payload, serde: JsonSerde); end

    # Reject a durable promise with a terminal failure.
    sig { abstract.params(name: String, message: String, code: Integer).void }
    def reject_promise(name, message, code: 500); end
  end
end
# rubocop:enable Metrics/ModuleLength,Metrics/ParameterLists,Style/EmptyMethod
