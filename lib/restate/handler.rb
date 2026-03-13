# frozen_string_literal: true

module Restate
  # Identifies which service a handler belongs to.
  ServiceTag = Struct.new(:kind, :name, :description, :metadata, keyword_init: true)

  # Describes the input/output serialization for a handler.
  HandlerIO = Struct.new(:accept, :content_type, :input_serde, :output_serde, keyword_init: true) do
    def initialize(accept: "application/json", content_type: "application/json",
                   input_serde: JsonSerde, output_serde: JsonSerde)
      super
    end
  end

  # A registered handler with its metadata and callable block.
  Handler = Struct.new(
    :service_tag, :handler_io, :kind, :name, :callable, :arity,
    keyword_init: true
  )

  module_function

  # Invoke a handler with the given context and raw input bytes.
  # Returns raw output bytes.
  def invoke_handler(handler:, ctx:, in_buffer:)
    if handler.arity == 2
      begin
        in_arg = handler.handler_io.input_serde.deserialize(in_buffer)
      rescue => e
        raise TerminalError.new("Unable to parse input argument: #{e.message}")
      end
      out_arg = handler.callable.call(ctx, in_arg)
    else
      out_arg = handler.callable.call(ctx)
    end
    handler.handler_io.output_serde.serialize(out_arg)
  end
end
