# frozen_string_literal: true

module Restate
  # A keyed virtual object with durable state.
  #
  # Example:
  #   counter = Restate::VirtualObject.new("Counter")
  #   counter.handler("add", kind: :exclusive) do |ctx, value|
  #     current = ctx.get("count") || 0
  #     ctx.set("count", current + value)
  #     current + value
  #   end
  class VirtualObject
    attr_reader :service_tag, :handlers

    def initialize(name, description: nil, metadata: nil)
      @service_tag = ServiceTag.new(kind: "object", name: name, description: description, metadata: metadata)
      @handlers = {}
    end

    def name
      @service_tag.name
    end

    # Register a handler.
    #
    # @param name [String] handler name
    # @param kind [:exclusive, :shared] concurrency mode (default :exclusive)
    # @param input_serde, output_serde serializers
    # @yield [ctx] or [ctx, input]
    def handler(name, kind: :exclusive, accept: "application/json", content_type: "application/json",
                input_serde: JsonSerde, output_serde: JsonSerde, &block)
      raise ArgumentError, "Block required for handler" unless block_given?

      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: input_serde, output_serde: output_serde
      )

      h = Handler.new(
        service_tag: @service_tag,
        handler_io: handler_io,
        kind: kind.to_s,
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end
  end
end
