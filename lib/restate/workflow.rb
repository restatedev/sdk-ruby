# typed: true
# frozen_string_literal: true

module Restate
  # A durable workflow with a main entry point and shared handlers.
  #
  # @example
  #   class Signup < Restate::Workflow
  #     main def run(email)
  #       # workflow logic
  #     end
  #
  #     handler def status
  #       ctx = Restate.current_workflow_context
  #       ctx.get("status")
  #     end
  #   end
  class Workflow
    extend T::Sig
    extend ServiceDSL

    # Register the main workflow entry point.
    # Use as: +main def run(arg)+ or +main :run, input: String+
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

      _register_handler(method_name, **T.unsafe({ kind: 'workflow', **opts }))
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

      _register_handler(method_name, **T.unsafe({ kind: 'shared', **opts }))
    end

    def self._service_kind
      'workflow'
    end
  end
end
