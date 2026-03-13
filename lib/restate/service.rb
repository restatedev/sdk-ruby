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
    attr_reader :service_tag, :handlers

    def initialize(name, description: nil, metadata: nil)
      @service_tag = ServiceTag.new(kind: "service", name: name, description: description, metadata: metadata)
      @handlers = {}
    end

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
    def handler(name, accept: "application/json", content_type: "application/json",
                input_serde: JsonSerde, output_serde: JsonSerde, &block)
      raise ArgumentError, "Block required for handler" unless block_given?

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
