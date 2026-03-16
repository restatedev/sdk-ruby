# typed: true
# frozen_string_literal: true

module Restate
  # A keyed virtual object with durable state.
  #
  # @example
  #   class Counter < Restate::VirtualObject
  #     handler def add(addend)
  #       ctx = Restate.current_object_context
  #       old = ctx.get("count") || 0
  #       ctx.set("count", old + addend)
  #       old + addend
  #     end
  #
  #     shared def get
  #       ctx = Restate.current_object_context
  #       ctx.get("count") || 0
  #     end
  #   end
  class VirtualObject
    extend T::Sig
    extend ServiceDSL

    # Register an exclusive handler. Use as: +handler def my_method(arg)+
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

    def self._service_kind
      'object'
    end
  end
end
