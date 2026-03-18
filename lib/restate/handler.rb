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
    :description, :metadata,
    :inactivity_timeout, :abort_timeout,
    :journal_retention, :idempotency_retention,
    :workflow_completion_retention,
    :ingress_private,
    :invocation_retry_policy,
    keyword_init: true
  )

  extend T::Sig

  module_function

  # Invoke a handler with the context and raw input bytes.
  # The context is passed as the first argument to every handler.
  # Returns raw output bytes.
  sig { params(handler: T.untyped, ctx: T.untyped, in_buffer: String).returns(String) }
  def invoke_handler(handler:, ctx:, in_buffer:)
    if handler.arity == 2
      begin
        in_arg = handler.handler_io.input_serde.deserialize(in_buffer)
      rescue StandardError => e
        Kernel.raise TerminalError, "Unable to parse input argument: #{e.message}"
      end
      out_arg = handler.callable.call(ctx, in_arg)
    else
      out_arg = handler.callable.call(ctx)
    end
    handler.handler_io.output_serde.serialize(out_arg)
  end
end
