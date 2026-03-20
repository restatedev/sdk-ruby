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
