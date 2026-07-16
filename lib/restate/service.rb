# typed: false
# frozen_string_literal: true

module Restate
  # A stateless Restate service.
  #
  # @example
  #   class Greeter < Restate::Service
  #     handler def greet(ctx, name)
  #       ctx.run_sync('build-greeting') { "Hello, #{name}!" }
  #     end
  #   end
  class Service
    extend ServiceDSL

    # Register a handler method on this service.
    # Use as: +handler def my_method(ctx, arg)+ or +handler :my_method, input: String+
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

      _register_handler(method_name, kind: nil, **opts)
    end

    # Returns a call proxy for fluent durable calls to this service.
    #
    # @example
    #   Greeter.call.greet("World").await
    #   Greeter.call(scope: "tenant1", limit_key: "tenant1/user42").greet("World").await
    #
    # @param scope [String, nil] optional scope to route the call within (see {Restate.scope})
    # @param limit_key [String, nil] optional concurrency limit key within the scope
    # @return [ServiceCallProxy]
    def self.call(scope: nil, limit_key: nil)
      ServiceCallProxy.new(self, call_method: :service_call, scope: scope, limit_key: limit_key)
    end

    # Returns a send proxy for fluent fire-and-forget sends to this service.
    #
    # @example
    #   Greeter.send!.greet("World")
    #   Greeter.send!(delay: 60).greet("World")
    #   Greeter.send!(scope: "tenant1", limit_key: "tenant1/user42").greet("World")
    #
    # @param delay [Numeric, nil] optional delay in seconds
    # @param scope [String, nil] optional scope to route the send within (see {Restate.scope})
    # @param limit_key [String, nil] optional concurrency limit key within the scope
    # @return [ServiceSendProxy]
    def self.send!(delay: nil, scope: nil, limit_key: nil)
      ServiceSendProxy.new(self, send_method: :service_send, delay: delay, scope: scope, limit_key: limit_key)
    end

    def self._service_kind
      'service'
    end
  end
end
