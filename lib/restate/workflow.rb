# typed: false
# frozen_string_literal: true

module Restate
  # A durable workflow with a main entry point and shared handlers.
  #
  # Class-based API (preferred):
  #   class Signup < Restate::Workflow
  #     main def run(ctx, email)
  #       # workflow logic
  #     end
  #
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
    def self.main(method_name = nil, **opts)
      return _instance_main(method_name, **opts) { |*args| yield(*args) } if block_given?
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, kind: 'workflow', **opts)
    end

    # Register a shared handler.
    def self.handler(method_name = nil, **opts)
      return super unless method_name.is_a?(Symbol)

      _register_handler(method_name, kind: 'shared', **opts)
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

    def service_name
      name
    end

    # Register the main workflow entry point (instance-based API).
    def main(name, accept: 'application/json', content_type: 'application/json',
             input_serde: JsonSerde, output_serde: JsonSerde, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: input_serde, output_serde: output_serde
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
    def handler(name, accept: 'application/json', content_type: 'application/json',
                input_serde: JsonSerde, output_serde: JsonSerde, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: input_serde, output_serde: output_serde
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
