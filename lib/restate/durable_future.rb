# typed: true
# frozen_string_literal: true

module Restate
  # A durable future wrapping a VM handle. Lazily resolves on first +await+ and caches the result.
  # Returned by +ctx.run+ and +ctx.sleep+.
  class DurableFuture
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :handle

    sig { params(ctx: ServerContext, handle: Integer, serde: T.untyped).void }
    def initialize(ctx, handle, serde: nil)
      @ctx = T.let(ctx, ServerContext)
      @handle = T.let(handle, Integer)
      @serde = T.let(serde, T.untyped)
      @resolved = T.let(false, T::Boolean)
      @value = T.let(nil, T.untyped)
    end

    # Block until the result is available and return it. Caches across calls.
    #
    # @return [Object] the deserialized result
    sig { returns(T.untyped) }
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
    sig { returns(T::Boolean) }
    def completed?
      @resolved || @ctx.completed?(@handle)
    end
  end

  # A durable future for service/object/workflow calls.
  # Adds +invocation_id+ and +cancel+ on top of DurableFuture.
  # Returned by +ctx.service_call+, +ctx.object_call+, +ctx.workflow_call+.
  class DurableCallFuture < DurableFuture
    extend T::Sig

    sig do
      params(
        ctx: ServerContext,
        result_handle: Integer,
        invocation_id_handle: Integer,
        output_serde: T.untyped
      ).void
    end
    def initialize(ctx, result_handle, invocation_id_handle, output_serde:)
      super(ctx, result_handle)
      @invocation_id_handle = T.let(invocation_id_handle, Integer)
      @output_serde = T.let(output_serde, T.untyped)
      @invocation_id_resolved = T.let(false, T::Boolean)
      @invocation_id_value = T.let(nil, T.untyped)
    end

    # Block until the result is available and return it. Deserializes via +output_serde+.
    sig { returns(T.untyped) }
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
    sig { returns(String) }
    def invocation_id
      unless @invocation_id_resolved
        @invocation_id_value = @ctx.resolve_handle(@invocation_id_handle)
        @invocation_id_resolved = true
      end
      T.must(@invocation_id_value)
    end

    # Cancel the remote invocation.
    sig { void }
    def cancel
      @ctx.cancel_invocation(invocation_id)
    end
  end

  # A handle for fire-and-forget send operations.
  # Returned by +ctx.service_send+, +ctx.object_send+, +ctx.workflow_send+.
  class SendHandle
    extend T::Sig

    sig { params(ctx: ServerContext, invocation_id_handle: Integer).void }
    def initialize(ctx, invocation_id_handle)
      @ctx = T.let(ctx, ServerContext)
      @invocation_id_handle = T.let(invocation_id_handle, Integer)
      @invocation_id_resolved = T.let(false, T::Boolean)
      @invocation_id_value = T.let(nil, T.untyped)
    end

    # Returns the invocation ID of the sent call. Lazily resolved.
    #
    # @return [String] the invocation ID
    sig { returns(String) }
    def invocation_id
      unless @invocation_id_resolved
        @invocation_id_value = @ctx.resolve_handle(@invocation_id_handle)
        @invocation_id_resolved = true
      end
      T.must(@invocation_id_value)
    end

    # Cancel the remote invocation.
    sig { void }
    def cancel
      @ctx.cancel_invocation(invocation_id)
    end
  end
end
