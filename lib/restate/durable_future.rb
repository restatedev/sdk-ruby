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

    # Block until the result is available and return it. Caches across calls,
    # including failures — a second await on a failed future re-raises the
    # same +TerminalError+ rather than re-fetching from the VM (the notification
    # is single-shot).
    #
    # @return [Object] the deserialized result
    def await
      resolve! unless @resolved
      raise @error if @error

      @value
    end

    # Check whether the future has completed (non-blocking).
    #
    # @return [Boolean]
    def completed?
      @resolved || @ctx.completed?(@handle)
    end

    # Race +self+ against +Restate.sleep(duration)+. Returns the value
    # if the future wins; raises {Restate::TimeoutError} otherwise.
    # Does not cancel the underlying work (matches TS/Java SDKs); on
    # a {DurableCallFuture}, call +#cancel+ in the rescue if you want
    # the remote invocation stopped.
    def or_timeout(duration)
      sleep_future = Restate.sleep(duration)
      Restate.wait_any(self, sleep_future)
      return await if completed?

      raise TimeoutError
    end

    private

    def resolve!
      raw = @ctx.resolve_handle(@handle)
      @value = @serde ? @serde.deserialize(raw) : raw
    rescue TerminalError => e
      @error = e
    ensure
      @resolved = true
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
    # Caches both successes and TerminalError failures across calls.
    def await
      resolve_call! unless @resolved
      raise @error if @error

      @value
    end

    private

    def resolve_call!
      raw = @ctx.resolve_handle(@handle)
      @value = if raw.nil? || @output_serde.nil?
                 raw
               else
                 @output_serde.deserialize(raw)
               end
    rescue TerminalError => e
      @error = e
    ensure
      @resolved = true
    end

    public

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

  # A lazy combinator over one or more child futures. The child set can mix
  # +DurableFuture+ leaves (with raw handles) and nested +CombinedFuture+ nodes.
  # The shared-core uses the tree shape to make suspension decisions; nothing
  # blocks until +.await+ is called, so combinators are composable:
  #
  #   Restate.race(Restate.all(a, b), c).await
  #
  # Supported variants (mirroring +UnresolvedFuture+ in restate-sdk-shared-core):
  #   :first_completed                 → JS Promise.race
  #   :all_succeeded_or_first_failed   → JS Promise.all
  #   :first_succeeded_or_all_failed   → JS Promise.any
  #   :all_completed                   → JS Promise.allSettled
  class CombinedFuture
    VALID_VARIANTS = %i[
      first_completed
      all_succeeded_or_first_failed
      first_succeeded_or_all_failed
      all_completed
    ].freeze

    def initialize(ctx, variant, children)
      raise ArgumentError, "unknown combinator variant: #{variant}" unless VALID_VARIANTS.include?(variant)

      @ctx = ctx
      @variant = variant
      @children = children
      @resolved = false
      @value = nil
      @error = nil
    end

    # Recursive tree representation the native +do_await+ binding consumes.
    # Leaves are integer handles; inner nodes are +[variant, [child...]]+ pairs.
    def tree
      [@variant, @children.map { |c| c.is_a?(CombinedFuture) ? c.tree : c.handle }]
    end

    # Block until this combinator settles per its variant. Caches results
    # (including failures) across calls.
    def await
      resolve_combined! unless @resolved
      raise @error if @error

      @value
    end

    # Non-blocking introspection. True iff calling +.await+ is guaranteed not to
    # block. Conservative for the variants that allow early-completion on failure
    # (+:all_succeeded_or_first_failed+, +:first_succeeded_or_all_failed+) — we
    # report false until every child is settled, because checking failure status
    # of a leaf would require consuming its notification.
    def completed?
      return true if @resolved

      case @variant
      when :first_completed
        @children.any?(&:completed?)
      else
        @children.all?(&:completed?)
      end
    end

    private

    def resolve_combined!
      @ctx.wait_combined(tree)
      @value = finalize_value
    rescue TerminalError => e
      @error = e
    ensure
      @resolved = true
    end

    def finalize_value
      case @variant
      when :first_completed then finalize_first_completed
      when :all_succeeded_or_first_failed then finalize_all_succeeded
      when :all_completed then finalize_all_completed
      when :first_succeeded_or_all_failed then finalize_first_succeeded
      end
    end

    def finalize_first_completed
      @children.find(&:completed?).await
    end

    def finalize_all_succeeded
      # Surface any settled-and-failed child first (short-circuit). After this
      # scan, if no failure was raised, every child must be settled-and-success
      # per AllSucceededOrFirstFailed semantics.
      @children.each { |c| c.await if c.completed? }
      @children.map(&:await)
    end

    def finalize_all_completed
      @children.map do |c|
        { status: :fulfilled, value: c.await }
      rescue TerminalError => e
        { status: :rejected, reason: e }
      end
    end

    def finalize_first_succeeded
      errors = [] # : Array[TerminalError]
      @children.each do |c|
        next unless c.completed?

        return c.await
      rescue TerminalError => e
        errors << e
      end
      raise TerminalError.new("all futures failed: #{errors.map(&:message).join('; ')}",
                              status_code: 500)
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
