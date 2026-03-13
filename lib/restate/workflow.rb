# frozen_string_literal: true

module Restate
  # A durable workflow with a main entry point and shared handlers.
  #
  # Example:
  #   signup = Restate::Workflow.new("Signup")
  #   signup.main("run") do |ctx, email|
  #     # workflow logic
  #   end
  #   signup.handler("status") do |ctx|
  #     ctx.get("status")
  #   end
  class Workflow
    attr_reader :service_tag, :handlers

    def initialize(name, description: nil, metadata: nil)
      @service_tag = ServiceTag.new(kind: "workflow", name: name, description: description, metadata: metadata)
      @handlers = {}
    end

    def name
      @service_tag.name
    end

    # Register the main workflow entry point.
    # Runs with "workflow" handler kind (exclusive, runs-once-per-key).
    def main(name, accept: "application/json", content_type: "application/json",
             input_serde: JsonSerde, output_serde: JsonSerde, &block)
      raise ArgumentError, "Block required for main handler" unless block_given?

      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: input_serde, output_serde: output_serde
      )

      h = Handler.new(
        service_tag: @service_tag,
        handler_io: handler_io,
        kind: "workflow",
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end

    # Register a shared handler (can run concurrently, read-only state).
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
        kind: "shared",
        name: name,
        callable: block,
        arity: block.arity.abs
      )
      @handlers[name] = h
      self
    end
  end
end
