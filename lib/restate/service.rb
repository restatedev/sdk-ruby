# typed: true
# frozen_string_literal: true

module Restate
  # A stateless Restate service.
  #
  # Example:
  #   greeter = Restate::Service.new("Greeter")
  #   greeter.handler("greet") do |ctx, name|
  #     "Hello, #{name}!"
  #   end
  class Service
    extend T::Sig

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

    # Register a handler.
    #
    # @param name [String] handler name
    # @param accept [String] accept content type
    # @param content_type [String] response content type
    # @param input_serde [#serialize, #deserialize] input serializer
    # @param output_serde [#serialize, #deserialize] output serializer
    # @yield [ctx] or [ctx, input] the handler block
    sig do
      params(
        name: String,
        accept: String,
        content_type: String,
        input_serde: T.untyped,
        output_serde: T.untyped,
        block: T.proc.params(arg0: T.untyped).returns(T.untyped)
      ).returns(T.self_type)
    end
    def handler(name, accept: 'application/json', content_type: 'application/json',
                input_serde: JsonSerde, output_serde: JsonSerde, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: input_serde, output_serde: output_serde
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
