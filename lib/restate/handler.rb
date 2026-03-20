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
  # Middleware (if any) wraps the handler call.
  # Returns raw output bytes.
  sig do
    params(handler: T.untyped, ctx: T.untyped, in_buffer: String,
           middleware: T::Array[T.untyped]).returns(String)
  end
  def invoke_handler(handler:, ctx:, in_buffer:, middleware: []) # rubocop:disable Metrics/AbcSize
    call_handler = Kernel.proc do
      if handler.arity == 1
        begin
          in_arg = handler.handler_io.input_serde.deserialize(in_buffer)
        rescue StandardError => e
          Kernel.raise TerminalError, "Unable to parse input argument: #{e.message}"
        end
        handler.callable.call(in_arg)
      else
        handler.callable.call
      end
    end

    # Build the middleware chain so each middleware can use `yield` to call the next.
    # Middleware still receives (handler, ctx) for low-level access.
    chain = middleware.reverse.reduce(call_handler) do |nxt, mw|
      Kernel.proc { mw.call(handler, ctx, &nxt) }
    end

    out_arg = chain.call
    handler.handler_io.output_serde.serialize(out_arg)
  end
end
