# typed: true
# frozen_string_literal: true

module Restate
  # Identifies which service a handler belongs to.
  ServiceTag = Struct.new(:kind, :name, :description, :metadata, keyword_init: true)

  # Describes the input/output serialization for a handler.
  # Schema is accessed via the serde's json_schema method.
  HandlerIO = Struct.new(:accept, :content_type, :input_serde, :output_serde, keyword_init: true) do
    def initialize(accept: 'application/json', content_type: 'application/json',
                   input_serde: JsonSerde, output_serde: JsonSerde)
      super
    end
  end

  # A registered handler with its metadata and callable block.
  Handler = Struct.new(
    :service_tag, :handler_io, :kind, :name, :callable, :arity,
    :enable_lazy_state,
    keyword_init: true
  )

  extend T::Sig

  module_function

  # Invoke a handler with raw input bytes. The context is available via
  # fiber-local Restate.current_context (set by ServerContext#enter).
  # Returns raw output bytes.
  sig { params(handler: T.untyped, in_buffer: String).returns(String) }
  def invoke_handler(handler:, in_buffer:)
    if handler.arity == 1
      begin
        in_arg = handler.handler_io.input_serde.deserialize(in_buffer)
      rescue StandardError => e
        Kernel.raise TerminalError, "Unable to parse input argument: #{e.message}"
      end
      out_arg = handler.callable.call(in_arg)
    else
      out_arg = handler.callable.call
    end
    handler.handler_io.output_serde.serialize(out_arg)
  end
end
