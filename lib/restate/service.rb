# typed: true
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

    # Register a handler method on this service.
    # Use as: +handler def my_method(ctx, arg)+ or +handler :my_method, input: String+
    #
    # @param method_name [Symbol] name of the method to register
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.handler(method_name = nil, **opts)
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: nil, **opts }))
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

    # Returns the service name.
    sig { returns(String) }
    def service_name
      name
    end

    # Register a handler on this instance-based service.
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
