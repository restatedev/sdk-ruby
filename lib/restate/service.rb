# typed: false
# frozen_string_literal: true

module Restate
  # A stateless Restate service.
  #
  # Class-based API (preferred):
  #   class Greeter < Restate::Service
  #     handler def greet(ctx, name)
  #       "Hello, #{name}!"
  #     end
  #   end
  #
  # Instance-based API (legacy, still supported):
  #   greeter = Restate::Service.new("Greeter")
  #   greeter.handler("greet") do |ctx, name|
  #     "Hello, #{name}!"
  #   end
  class Service
    extend T::Sig
    extend ServiceDSL

    # -- Class-level DSL (for subclasses) --

    # @!method self.handler(method_name, **opts)
    #   Register a handler. Use as: `handler def my_method(ctx, arg)`
    def self.handler(method_name = nil, **opts)
      return super unless method_name.is_a?(Symbol)

      _register_handler(method_name, kind: nil, **opts)
    end

    def self._service_kind
      'service'
    end

    # -- Instance-based API (legacy) --

    sig { returns(T.untyped) }
    attr_reader :service_tag

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :handlers

    sig { params(name: String, description: T.nilable(String), metadata: T.untyped).void }
    def initialize(name, description: nil, metadata: nil)
      @service_tag = T.let(
        ServiceTag.new(kind: 'service', name: name, description: description, metadata: metadata),
        T.untyped
      )
      @handlers = T.let({}, T::Hash[String, T.untyped])
    end

    sig { returns(String) }
    def name
      @service_tag.name
    end

    # Alias for compatibility: both class-based and instance-based use service_name
    def service_name
      name
    end

    # Register a handler (instance-based API).
    def handler(name, accept: 'application/json', content_type: 'application/json',
                input: nil, output: nil, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: Serde.resolve(input), output_serde: Serde.resolve(output)
      )

      h = Handler.new(
        service_tag: @service_tag,
        handler_io: handler_io,
        kind: nil,
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end
  end
end
