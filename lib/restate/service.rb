# typed: true
# frozen_string_literal: true

module Restate
  # A stateless Restate service.
  #
  # @example
  #   class Greeter < Restate::Service
  #     handler def greet(name)
  #       "Hello, #{name}!"
  #     end
  #   end
  class Service
    extend T::Sig
    extend ServiceDSL

    # Register a handler method on this service.
    # Use as: +handler def my_method(arg)+ or +handler :my_method, input: String+
    #
    # @param method_name [Symbol] name of the method to register
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.handler(method_name = nil, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `handler def #{method_name}(...)` or `handler :#{method_name}`)"
      end
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: nil, **opts }))
    end

    def self._service_kind
      'service'
    end
  end
end
