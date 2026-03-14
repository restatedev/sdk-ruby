# typed: true
# frozen_string_literal: true

module Restate
  # A durable workflow with a main entry point and shared handlers.
  #
  # Class-based API (preferred):
  #   class Signup < Restate::Workflow
  #     # @param ctx [Restate::WorkflowContext]
  #     main def run(ctx, email)
  #       # workflow logic
  #     end
  #
  #     # @param ctx [Restate::WorkflowContext]
  #     handler def status(ctx)
  #       ctx.get("status")
  #     end
  #   end
  #
  # Instance-based API (legacy, still supported):
  #   signup = Restate::Workflow.new("Signup")
  #   signup.main("run") do |ctx, email|
  #     ...
  #   end
  class Workflow
    extend T::Sig
    extend ServiceDSL

    # -- Class-level DSL (for subclasses) --

    # Register the main workflow entry point.
    # Use as: +main def run(ctx, arg)+ or +main :run, input: String+
    #
    # @param method_name [Symbol] name of the method to register
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.main(method_name = nil, **opts)
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: 'workflow', **opts }))
    end

    # Register a shared handler on this workflow.
    #
    # @param method_name [Symbol] name of the method to register
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.handler(method_name = nil, **opts)
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: 'shared', **opts }))
    end

    def self._service_kind
      'workflow'
    end

    # -- Instance-based API (legacy) --

    sig { returns(T.untyped) }
    attr_reader :service_tag

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :handlers

    sig { params(name: String, description: T.nilable(String), metadata: T.untyped).void }
    def initialize(name, description: nil, metadata: nil)
      @service_tag = T.let(
        ServiceTag.new(kind: 'workflow', name: name, description: description, metadata: metadata),
        T.untyped
      )
      @handlers = T.let({}, T::Hash[String, T.untyped])
    end

    sig { returns(String) }
    def name
      @service_tag.name
    end

    # Returns the service name.
    sig { returns(String) }
    def service_name
      name
    end

    # Register the main workflow entry point (instance-based API).
    #
    # @param name [String] the handler name
    # @param input [Class, #serialize, nil] type or serde for input deserialization
    # @param output [Class, #serialize, nil] type or serde for output serialization
    # @yield [ctx, input] the handler block
    # @return [self]
    def main(name, accept: 'application/json', content_type: 'application/json',
             input: nil, output: nil, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: Serde.resolve(input), output_serde: Serde.resolve(output)
      )

      h = Handler.new(
        service_tag: @service_tag,
        handler_io: handler_io,
        kind: 'workflow',
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end

    # Register a shared handler (instance-based API).
    #
    # @param name [String] the handler name
    # @param input [Class, #serialize, nil] type or serde for input deserialization
    # @param output [Class, #serialize, nil] type or serde for output serialization
    # @yield [ctx, input] the handler block
    # @return [self]
    def handler(name, accept: 'application/json', content_type: 'application/json',
                input: nil, output: nil, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: Serde.resolve(input), output_serde: Serde.resolve(output)
      )

      h = Handler.new(
        service_tag: @service_tag,
        handler_io: handler_io,
        kind: 'shared',
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end
  end
end
