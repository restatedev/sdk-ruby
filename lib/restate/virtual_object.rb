# typed: true
# frozen_string_literal: true

module Restate
  # A keyed virtual object with durable state.
  #
  # @example
  #   class Counter < Restate::VirtualObject
  #     handler def add(ctx, addend)
  #       old = ctx.get("count") || 0
  #       ctx.set("count", old + addend)
  #       old + addend
  #     end
  #
  #     shared def get(ctx)
  #       ctx.get("count") || 0
  #     end
  #   end
  class VirtualObject
    extend T::Sig
    extend ServiceDSL

    # Register an exclusive handler. Use as: +handler def my_method(ctx, arg)+
    #
    # @param method_name [Symbol] name of the method to register
    # @param kind [Symbol] concurrency mode (+:exclusive+ or +:shared+)
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.handler(method_name = nil, kind: :exclusive, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `handler def #{method_name}(...)` or `handler :#{method_name}`)"
      end
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: kind.to_s, **opts }))
    end

    # Register a shared (concurrent-access) handler.
    #
    # @param method_name [Symbol] name of the method to register
    # @return [Symbol] the method name
    def self.shared(method_name, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `shared def #{method_name}(...)` or `shared :#{method_name}`)"
      end

      _register_handler(method_name, **T.unsafe({ kind: 'shared', **opts }))
    end

    # Returns a call proxy for fluent durable calls to this virtual object.
    #
    # @example
    #   Counter.call("my-key").add(5).await
    #
    # @param key [String] the object key
    # @return [ServiceCallProxy]
    def self.call(key)
      ServiceCallProxy.new(self, key: key, call_method: :object_call)
    end

    # Returns a send proxy for fluent fire-and-forget sends to this virtual object.
    #
    # @example
    #   Counter.send!("my-key").add(5)
    #   Counter.send!("my-key", delay: 60).add(5)
    #
    # @param key [String] the object key
    # @param delay [Numeric, nil] optional delay in seconds
    # @return [ServiceSendProxy]
    def self.send!(key, delay: nil)
      ServiceSendProxy.new(self, key: key, send_method: :object_send, delay: delay)
    end

    def self._service_kind
      'object'
    end
  end
end
