# typed: false
# frozen_string_literal: true

require 'base64'
require 'set'

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
    # Injects the held-locks header into every outbound service call. When
    # handler metadata is available (the target service class is known), only
    # raises for exclusive handlers — shared handler calls are safe. Falls
    # back to raising for any same-service call when metadata is unavailable
    # (e.g., calling by string name to an external service).
    #
    # == Wire format
    #
    # Lock entries are encoded as +base64url(service).base64url(key)+ and
    # separated by commas. Base64url encoding ensures arbitrary service names
    # and keys (including those containing +.+, +,+, or non-ASCII characters)
    # are handled correctly.
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
      ENTRY_SEPARATOR = ','
      FIELD_SEPARATOR = '.'
      DEADLOCK_STATUS_CODE = 409

      THREAD_KEY = :restate_held_exclusive_locks

      class << self
        # Returns the current set of held exclusive locks for this fiber.
        # Each entry is a two-element array: [service_name, key].
        #
        # @return [Set<Array<String>>]
        def held_locks
          Thread.current[THREAD_KEY] || Set.new
        end

        # @param locks [Set<Array<String>>]
        def held_locks=(locks)
          Thread.current[THREAD_KEY] = locks
        end

        # Encodes a [service, key] pair into a wire-safe string.
        def encode_lock(service, key)
          b64_svc = Base64.urlsafe_encode64(service, padding: false)
          b64_key = Base64.urlsafe_encode64(key, padding: false)
          "#{b64_svc}#{FIELD_SEPARATOR}#{b64_key}"
        end

        # Decodes a wire-format lock string into [service, key].
        # Returns nil if the format is invalid.
        def decode_lock(encoded)
          parts = encoded.split(FIELD_SEPARATOR, 2)
          return nil unless parts.length == 2

          svc = Base64.urlsafe_decode64(parts[0]).force_encoding('UTF-8')
          key = Base64.urlsafe_decode64(parts[1]).force_encoding('UTF-8')
          [svc, key]
        rescue ArgumentError
          nil
        end

        # Serializes a set of [service, key] lock pairs into a header value.
        def encode_header(locks)
          locks.map { |svc, key| encode_lock(svc, key) }.join(ENTRY_SEPARATOR)
        end

        # Deserializes a header value into a Set of [service, key] pairs.
        def decode_header(raw)
          return Set.new if raw.nil? || raw.to_s.empty?

          entries = raw.to_s.split(ENTRY_SEPARATOR).filter_map do |entry|
            decode_lock(entry.strip)
          end
          Set.new(entries)
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
          lock = [svc, key]
          raise_deadlock!(svc, handler.name, key, incoming) if incoming.include?(lock)
          incoming << lock
        end

        def raise_deadlock!(svc, handler_name, key, locks)
          held = locks.map { |s, k| "#{s}:#{k}" }.join(', ')
          msg = "Deadlock detected: #{svc}##{handler_name} on key '#{key}' " \
                'called while an exclusive handler holds the same VO key. ' \
                "Held locks: #{held}. " \
                'This call will never complete.'
          Kernel.raise DeadlockError, msg
        end

        def parse_locks(ctx)
          headers = ctx.request.headers
          raw = headers.is_a?(Hash) ? headers[HEADER] : nil
          DeadlockDetection.decode_header(raw)
        end
      end

      # Outbound middleware that propagates held locks via headers.
      #
      # When handler metadata is available (via Thread.current[:restate_outbound_handler_meta]),
      # shared handler calls are allowed through — only exclusive handlers can deadlock.
      # When metadata is unavailable (external service called by string name), falls
      # back to raising for any same-service call.
      #
      # Register with: +endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)+
      #
      # @example
      #   endpoint = Restate.endpoint(MyVirtualObject)
      #   endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)
      class Outbound
        def call(service, handler, headers)
          locks = DeadlockDetection.held_locks
          propagate_and_check!(service, handler, headers, locks) if locks.any?
          yield
        end

        private

        def propagate_and_check!(service, handler, headers, locks)
          headers[HEADER] = DeadlockDetection.encode_header(locks)

          held_lock = locks.find { |svc, _key| svc == service }
          return unless held_lock

          return if target_shared?

          msg = "Deadlock detected: outbound call to #{service}##{handler} " \
                "while exclusive lock held on #{held_lock[0]}:#{held_lock[1]}. " \
                'This call will block forever.'
          Kernel.raise DeadlockError, msg
        end

        def target_shared?
          meta = Thread.current[:restate_outbound_handler_meta]
          meta&.kind == 'shared'
        end
      end
    end
  end
end
