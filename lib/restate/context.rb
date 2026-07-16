# typed: false
# frozen_string_literal: true

# rubocop:disable Style/EmptyMethod
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
    def initialize
      @mutex = Mutex.new
      @set = false
      @waiters = []
    end

    # Returns true if the attempt has finished.
    def set?
      @set
    end

    # Blocks the current fiber/thread until the attempt finishes.
    def wait
      return if @set

      waiter = nil
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
  # @!attribute [r] scope
  #   @return [String, nil] the scope this invocation was routed within, if any
  # @!attribute [r] limit_key
  #   @return [String, nil] the concurrency limit key this invocation was made with, if any
  # @!attribute [r] idempotency_key
  #   @return [String, nil] the idempotency key this invocation was made with, if any
  Request = Struct.new(:id, :headers, :body, :attempt_finished_event,
                       :scope, :limit_key, :idempotency_key, keyword_init: true)

  # Base context interface for all Restate handlers.
  #
  # Provides durable execution (+run+, +run_sync+), timers (+sleep+),
  # service-to-service calls, awakeables, and request metadata.
  #
  # @see ObjectContext for VirtualObject handlers (adds state operations)
  # @see WorkflowContext for Workflow handlers (adds promise operations)
  module Context
    # Execute a durable side effect. The block runs at most once; the result
    # is journaled and replayed on retries.
    #
    # Pass +background: true+ to offload the block to a real OS Thread,
    # keeping the fiber event loop responsive for CPU-intensive work.
    def run(name, serde: JsonSerde, retry_policy: nil, background: false, &action); end

    # Convenience shortcut for +run(...).await+. Returns the result directly.
    # Accepts all the same options as +run+, including +background: true+.
    def run_sync(name, serde: JsonSerde, retry_policy: nil, background: false, &action); end

    # Durable timer that survives handler restarts.
    def sleep(seconds) # rubocop:disable Lint/UnusedMethodArgument
      Kernel.raise NotImplementedError
    end

    # Durably call a handler on a Restate service.
    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     input_serde: NOT_SET, output_serde: NOT_SET)
    end

    # Fire-and-forget send to a Restate service handler.
    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil,
                     headers: nil, input_serde: NOT_SET)
    end

    # Durably call a handler on a Restate virtual object.
    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: NOT_SET, output_serde: NOT_SET)
    end

    # Fire-and-forget send to a Restate virtual object handler.
    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                    headers: nil, input_serde: NOT_SET)
    end

    # Durably call a handler on a Restate workflow.
    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                      input_serde: NOT_SET, output_serde: NOT_SET)
    end

    # Fire-and-forget send to a Restate workflow handler.
    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil,
                      headers: nil, input_serde: NOT_SET)
    end

    # Durably call a handler using raw bytes (no serialization).
    def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     scope: nil, limit_key: nil)
    end

    # Fire-and-forget send using raw bytes (no serialization).
    def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil,
                     scope: nil, limit_key: nil)
    end

    # Returns a +ScopedContext+ that routes all outgoing calls within the given scope.
    #
    # NOTE: This API is in preview and is not enabled by default. To use it in
    # restate-server 1.7, enable the flow control and protocol v7 experimental
    # features via +RESTATE_EXPERIMENTAL_ENABLE_PROTOCOL_V7=true+ and
    # +RESTATE_EXPERIMENTAL_ENABLE_VQUEUES=true+. These can be enabled only on new
    # clusters. If they aren't enabled, the call fails with a retryable error and
    # keeps retrying until they are.
    #
    # A scope is a sub-grouping of resources (invocations, workflow instances,
    # concurrency limits) within the Restate cluster. It becomes part of the target
    # identity tuple and contributes to the partition key, so all resources in a
    # scope get co-located by the restate-server. Omitting the scope (i.e. using the
    # regular +service_call+ / +workflow_call+ methods) is equivalent to calling
    # with no scope, which is the existing behavior.
    #
    # The scope must consist only of +[a-zA-Z0-9_.-]+ characters, 1 <= length <= 36.
    #
    # @param scope [String] the scope identifier
    # @return [ScopedContext]
    # @see https://docs.restate.dev/services/flow-control
    def scope(scope); end

    # Create an awakeable for external callbacks.
    # Returns [awakeable_id, DurableFuture].
    def awakeable(serde: JsonSerde); end

    # Resolve an awakeable with a success value.
    def resolve_awakeable(awakeable_id, payload, serde: JsonSerde); end

    # Reject an awakeable with a terminal failure.
    def reject_awakeable(awakeable_id, message, code: 500); end

    # Wait for a named signal addressed to this invocation.
    # Returns a DurableFuture that resolves once another invocation calls
    # +resolve_signal+ or +reject_signal+ with the same name targeting this
    # invocation's id.
    def signal(name, serde: JsonSerde); end

    # Send a success value to a named signal on another invocation.
    def resolve_signal(invocation_id, name, payload, serde: JsonSerde); end

    # Send a terminal failure to a named signal on another invocation.
    def reject_signal(invocation_id, name, message, code: 500); end

    # Request cancellation of another invocation.
    def cancel_invocation(invocation_id); end

    # Wait until any of the given futures completes.
    # Returns [completed, remaining].
    def wait_any(*futures); end

    # Returns metadata about the current invocation.
    def request; end

    # Returns the key for this virtual object or workflow invocation.
    def key; end
  end

  # Context interface for VirtualObject shared handlers (read-only state).
  # Extends {Context} with +get+, +state_keys+, and +key+ — but no mutations.
  module ObjectSharedContext
    include Context

    # Durably retrieve a state entry. Returns nil if unset.
    def get(name, serde: JsonSerde); end

    # Durably retrieve a state entry, returning a DurableFuture instead of blocking.
    def get_async(name, serde: JsonSerde); end

    # List all state entry names.
    def state_keys; end

    # List all state entry names, returning a DurableFuture instead of blocking.
    def state_keys_async; end
  end

  # Context interface for VirtualObject exclusive handlers (full state access).
  # Extends {ObjectSharedContext} with mutating state operations.
  module ObjectContext
    include ObjectSharedContext

    # Durably set a state entry.
    def set(name, value, serde: JsonSerde); end

    # Durably remove a single state entry.
    def clear(name); end

    # Durably remove all state entries.
    def clear_all; end
  end

  # Context interface for Workflow shared handlers (read-only state + promises).
  # Extends {ObjectSharedContext} with durable promise operations.
  module WorkflowSharedContext
    include ObjectSharedContext

    # Get a durable promise value, blocking until resolved.
    def promise(name, serde: JsonSerde); end

    # Peek at a durable promise without blocking. Returns nil if not yet resolved.
    def peek_promise(name, serde: JsonSerde); end

    # Resolve a durable promise with a value.
    def resolve_promise(name, payload, serde: JsonSerde); end

    # Reject a durable promise with a terminal failure.
    def reject_promise(name, message, code: 500); end
  end

  # Context interface for Workflow main handler (full state + promises).
  # Extends {ObjectContext} with durable promise operations.
  module WorkflowContext
    include ObjectContext

    # Get a durable promise value, blocking until resolved.
    def promise(name, serde: JsonSerde); end

    # Peek at a durable promise without blocking. Returns nil if not yet resolved.
    def peek_promise(name, serde: JsonSerde); end

    # Resolve a durable promise with a value.
    def resolve_promise(name, payload, serde: JsonSerde); end

    # Reject a durable promise with a terminal failure.
    def reject_promise(name, message, code: 500); end
  end
end
# rubocop:enable Style/EmptyMethod
