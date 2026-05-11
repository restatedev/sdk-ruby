# typed: false
# frozen_string_literal: true

module Restate
  module Middleware
    # Detects VirtualObject deadlocks caused by re-entrant calls to a VO whose
    # exclusive handler is still running higher up the call chain.
    #
    # == The problem
    #
    # Restate VirtualObjects serialize exclusive handler access per key. If handler A
    # on VO key "x" calls handler B on the same VO key "x", the call will block
    # forever — the key is already locked by A. This is a deadlock.
    #
    # == How it works
    #
    # This middleware tracks which VO keys are held by the current call chain and
    # propagates that information via a header on every outbound call.
    #
    # === Inbound side
    #
    # 1. Reads the held-locks header from the incoming request.
    # 2. If the current handler is an exclusive VO handler targeting a key already
    #    in the set → deadlock. Raises a {DeadlockError} immediately.
    # 3. If this handler is an exclusive VO handler, appends its lock to the set
    #    so further downstream calls propagate it.
    #
    # === Outbound side
    #
    # Injects the held-locks header into every outbound service call, and also
    # detects same-service deadlocks on the outbound side (calling the same VO
    # service while holding its lock).
    #
    # == Journal determinism
    #
    # The held-locks header is deterministic across replays: its value depends only
    # on the execution path, which Restate's journal guarantees is identical on
    # every replay.
    #
    # == Usage
    #
    #   endpoint = Restate.endpoint(MyVirtualObject)
    #   endpoint.use(Restate::Middleware::DeadlockDetection::Inbound)
    #   endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)
    #
    module DeadlockDetection
      HEADER = 'x-restate-held-locks'
      SEPARATOR = ','
      DEADLOCK_STATUS_CODE = 409

      # Thread-local storage key for the current set of held locks.
      # Uses Thread.current[] (fiber-scoped in Ruby 3.0+) to match the SDK's
      # context storage pattern and prevent leaks across child fibers.
      THREAD_KEY = :restate_held_exclusive_locks

      class << self
        # Returns the current set of held exclusive locks for this fiber.
        #
        # @return [Set<String>] Lock identifiers in the form "ServiceName:key"
        def held_locks
          Thread.current[THREAD_KEY] || Set.new
        end

        # Sets the held locks for the current fiber.
        #
        # @param locks [Set<String>] The lock set
        def held_locks=(locks)
          Thread.current[THREAD_KEY] = locks
        end
      end

      # Error raised when a deadlock is detected.
      #
      # Uses status code 409 (Conflict) to signal that retrying won't help.
      class DeadlockError < Restate::TerminalError
        def initialize(message)
          super(message, status_code: DEADLOCK_STATUS_CODE)
        end
      end

      # Inbound middleware that checks for and tracks VO locks.
      #
      # Register with: +endpoint.use(Restate::Middleware::DeadlockDetection::Inbound)+
      #
      # @example
      #   endpoint = Restate.endpoint(MyVirtualObject)
      #   endpoint.use(Restate::Middleware::DeadlockDetection::Inbound)
      class Inbound
        # @param handler [Restate::Handler] The handler being invoked
        # @param ctx [Restate::ServerContext] The invocation context
        # @yield Invokes the next middleware or the handler
        # @return [Object] The handler result
        # @raise [DeadlockError] If the call would deadlock
        def call(handler, ctx)
          previous = DeadlockDetection.held_locks
          incoming = parse_locks(ctx)
          check_and_track_lock!(handler, ctx, incoming)
          DeadlockDetection.held_locks = incoming
          yield
        ensure
          DeadlockDetection.held_locks = previous
        end

        private

        def check_and_track_lock!(handler, ctx, incoming)
          return unless handler.service_tag.kind == 'object'
          return unless handler.kind == 'exclusive'

          key = ctx.respond_to?(:key) ? ctx.key : nil
          return unless key

          svc = handler.service_tag.name
          lock_id = "#{svc}:#{key}"
          raise_deadlock!(svc, handler.name, key, incoming) if incoming.include?(lock_id)
          incoming << lock_id
        end

        def raise_deadlock!(svc, handler_name, key, locks)
          msg = "Deadlock detected: #{svc}##{handler_name} on key '#{key}' " \
                'called while an exclusive handler holds the same VO key. ' \
                "Held locks: #{locks.to_a.join(', ')}. " \
                'This call will never complete.'
          Kernel.raise DeadlockError, msg
        end

        def parse_locks(ctx)
          headers = ctx.request.headers
          raw = headers.is_a?(Hash) ? headers[HEADER] : nil
          return Set.new if raw.nil? || raw.to_s.empty?

          Set.new(raw.to_s.split(SEPARATOR).map(&:strip).reject(&:empty?))
        end
      end

      # Outbound middleware that propagates held locks via headers.
      #
      # Injects the held-locks header into outbound calls and raises early
      # if the outbound call targets a VO service whose lock is already held.
      #
      # Register with: +endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)+
      #
      # @example
      #   endpoint = Restate.endpoint(MyVirtualObject)
      #   endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)
      class Outbound
        # @param service [String] Target service name
        # @param handler [String] Target handler name
        # @param headers [Hash] Mutable headers hash for the outbound call
        # @yield Continues the outbound call
        # @return [Object] The call result
        # @raise [DeadlockError] If the call would deadlock
        def call(service, handler, headers)
          locks = DeadlockDetection.held_locks
          propagate_and_check!(service, handler, headers, locks) if locks.any?
          yield
        end

        private

        def propagate_and_check!(service, handler, headers, locks)
          headers[HEADER] = locks.to_a.join(SEPARATOR)

          prefix = "#{service}:"
          held_lock = locks.find { |l| l.start_with?(prefix) }
          return unless held_lock

          msg = "Deadlock detected: outbound call to #{service}##{handler} " \
                "while exclusive lock held on #{held_lock}. " \
                'This call will block forever.'
          Kernel.raise DeadlockError, msg
        end
      end
    end
  end
end
