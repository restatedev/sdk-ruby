# typed: false
# frozen_string_literal: true

module Restate
  # A durable workflow with a main entry point and shared handlers.
  #
  # @example
  #   class Signup < Restate::Workflow
  #     main def run(ctx, email)
  #       # workflow logic
  #     end
  #
  #     handler def status(ctx)
  #       ctx.get("status")
  #     end
  #   end
  class Workflow
    extend ServiceDSL

    # Register the main workflow entry point.
    # Use as: +main def run(ctx, arg)+ or +main :run, input: String+
    #
    # @param method_name [Symbol] name of the method to register
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.main(method_name = nil, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `main def #{method_name}(...)` or `main :#{method_name}`)"
      end
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, kind: 'workflow', **opts)
    end

    # Register a shared handler on this workflow.
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

      _register_handler(method_name, kind: 'shared', **opts)
    end

    # Returns a call proxy for fluent durable calls to this workflow.
    #
    # @example
    #   UserSignup.call("user42").run("user@example.com").await
    #   UserSignup.call("user42", scope: "tenant1", limit_key: "tenant1/user42").run(email).await
    #
    # @param key [String] the workflow key
    # @param scope [String, nil] optional scope to route the call within (see {Restate.scope})
    # @param limit_key [String, nil] optional concurrency limit key within the scope
    # @return [ServiceCallProxy]
    def self.call(key, scope: nil, limit_key: nil)
      ServiceCallProxy.new(self, key: key, call_method: :workflow_call, scope: scope, limit_key: limit_key)
    end

    # Returns a send proxy for fluent fire-and-forget sends to this workflow.
    #
    # @example
    #   UserSignup.send!("user42").run("user@example.com")
    #   UserSignup.send!("user42", delay: 60).run("user@example.com")
    #   UserSignup.send!("user42", scope: "tenant1", limit_key: "tenant1/user42").run(email)
    #
    # @param key [String] the workflow key
    # @param delay [Numeric, nil] optional delay in seconds
    # @param scope [String, nil] optional scope to route the send within (see {Restate.scope})
    # @param limit_key [String, nil] optional concurrency limit key within the scope
    # @return [ServiceSendProxy]
    def self.send!(key, delay: nil, scope: nil, limit_key: nil)
      ServiceSendProxy.new(
        self,
        key: key, send_method: :workflow_send,
        delay: delay, scope: scope, limit_key: limit_key
      )
    end

    def self._service_kind
      'workflow'
    end
  end
end
