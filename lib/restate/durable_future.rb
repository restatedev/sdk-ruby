# typed: true
# frozen_string_literal: true

module Restate
  # A durable future wrapping a VM handle. Lazily resolves on first +await+ and caches the result.
  # Returned by +ctx.run+ and +ctx.sleep+.
  class DurableFuture
    attr_reader :handle

    def initialize(ctx, handle, serde: nil)
      @ctx = ctx
      @handle = handle
      @serde = serde
      @resolved = false
      @value = nil
    end

    # Block until the result is available and return it. Caches across calls.
    #
    # @return [Object] the deserialized result
    def await
      unless @resolved
        raw = @ctx.resolve_handle(@handle)
        @value = @serde ? @serde.deserialize(raw) : raw
        @resolved = true
      end
      @value
    end

    # Check whether the future has completed (non-blocking).
    #
    # @return [Boolean]
    def completed?
      @resolved || @ctx.completed?(@handle)
    end

    # Race +self+ against a durable sleep of +duration+ seconds. Returns
    # the future's value if it completes first; raises
    # {Restate::TimeoutError} if the sleep wins.
    #
    # Mirrors +RestatePromise.orTimeout+ in the TypeScript SDK and
    # +Awaitable.orTimeout+ in the Java SDK.
    #
    # == Caveat: the sleep is not cancelled when this future wins
    #
    # The sleep timer is journaled and the underlying shared-core VM
    # exposes no primitive to cancel an in-flight sleep handle (only
    # +sys_cancel_invocation+ on a separate invocation). When the
    # future wins the race the sleep entry remains in this invocation's
    # journal and Restate's scheduler keeps a wake-up registered until
    # the duration elapses. The wake-up is a no-op against a completed
    # handler, but it keeps the invocation row alive in Restate's
    # state until the timer fires — meaningful on long durations.
    #
    # For long-running deadlines whose retention you care about,
    # route the timer through a separate cancellable invocation
    # (delayed +ctx.service_send+ to a small trigger service that
    # resolves an awakeable) and cancel the +SendHandle+ on success.
    #
    # @example
    #   ctx.service_call(MyService, :handler, payload).or_timeout(5)
    #
    # @param duration [Numeric] timeout in seconds
    # @return [Object] the future's value when it wins the race
    # @raise [Restate::TimeoutError] when the sleep wins
    def or_timeout(duration)
      sleep_future = Restate.sleep(duration)
      Restate.wait_any(self, sleep_future)
      return await if completed?

      raise TimeoutError
    end
  end

  # A durable future for service/object/workflow calls.
  # Adds +invocation_id+ and +cancel+ on top of DurableFuture.
  # Returned by +ctx.service_call+, +ctx.object_call+, +ctx.workflow_call+.
  class DurableCallFuture < DurableFuture
    def initialize(ctx, result_handle, invocation_id_handle, output_serde:)
      super(ctx, result_handle)
      @invocation_id_handle = invocation_id_handle
      @output_serde = output_serde
      @invocation_id_resolved = false
      @invocation_id_value = nil
    end

    # Block until the result is available and return it. Deserializes via +output_serde+.
    def await
      unless @resolved
        raw = @ctx.resolve_handle(@handle)
        @value = if raw.nil? || @output_serde.nil?
                   raw
                 else
                   @output_serde.deserialize(raw)
                 end
        @resolved = true
      end
      @value
    end

    # Returns the invocation ID of the remote call. Lazily resolved.
    #
    # @return [String] the invocation ID
    def invocation_id
      unless @invocation_id_resolved
        @invocation_id_value = @ctx.resolve_handle(@invocation_id_handle)
        @invocation_id_resolved = true
      end
      @invocation_id_value
    end

    # Cancel the remote invocation.
    def cancel
      @ctx.cancel_invocation(invocation_id)
    end

    # Race +self+ against a durable sleep of +duration+ seconds. On
    # success returns the call's value. On timeout the underlying
    # remote invocation is cancelled (via +sys_cancel_invocation+) so
    # the callee doesn't continue running after the caller has
    # given up.
    #
    # Refines {DurableFuture#or_timeout} by cleaning up the *call*
    # side of the race when the timer wins. The sleep side itself
    # cannot be cancelled today — see the parent method's docstring.
    #
    # @example
    #   result = ctx.service_call(MyService, :handler, payload).or_timeout(5)
    #
    # @param duration [Numeric] timeout in seconds
    # @return [Object] the call result when this future wins
    # @raise [Restate::TimeoutError] when the sleep wins; the remote
    #   invocation has been cancelled before the error is raised
    def or_timeout(duration)
      sleep_future = Restate.sleep(duration)
      Restate.wait_any(self, sleep_future)
      return await if completed?

      cancel
      raise TimeoutError
    end
  end

  # A handle for fire-and-forget send operations.
  # Returned by +ctx.service_send+, +ctx.object_send+, +ctx.workflow_send+.
  class SendHandle
    def initialize(ctx, invocation_id_handle)
      @ctx = ctx
      @invocation_id_handle = invocation_id_handle
      @invocation_id_resolved = false
      @invocation_id_value = nil
    end

    # Returns the invocation ID of the sent call. Lazily resolved.
    #
    # @return [String] the invocation ID
    def invocation_id
      unless @invocation_id_resolved
        @invocation_id_value = @ctx.resolve_handle(@invocation_id_handle)
        @invocation_id_resolved = true
      end
      @invocation_id_value
    end

    # Cancel the remote invocation.
    def cancel
      @ctx.cancel_invocation(invocation_id)
    end
  end
end
