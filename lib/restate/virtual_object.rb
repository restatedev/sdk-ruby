# typed: false
# frozen_string_literal: true

module Restate
  # A keyed virtual object with durable state.
  #
  # Class-based API (preferred):
  #   class Counter < Restate::VirtualObject
  #     handler def add(ctx, addend)
  #       old = ctx.get("count") || 0
  #       ctx.set("count", old + addend)
  #       old + addend
  #     end
  #
  #     shared def get(ctx)
  #       ctx.get("count") || 0
  #     end
  #   end
  #
  # Instance-based API (legacy, still supported):
  #   counter = Restate::VirtualObject.new("Counter")
  #   counter.handler("add") do |ctx, value|
  #     ...
  #   end
  class VirtualObject
    extend T::Sig
    extend ServiceDSL

    # -- Class-level DSL (for subclasses) --

    def self.handler(method_name = nil, kind: :exclusive, **opts)
      return super unless method_name.is_a?(Symbol)

      _register_handler(method_name, kind: kind.to_s, **opts)
    end

    def self.shared(method_name, **opts)
      _register_handler(method_name, kind: 'shared', **opts)
    end

    def self._service_kind
      'object'
    end

    # -- Instance-based API (legacy) --

    sig { returns(T.untyped) }
    attr_reader :service_tag

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :handlers

    sig { params(name: String, description: T.nilable(String), metadata: T.untyped).void }
    def initialize(name, description: nil, metadata: nil)
      @service_tag = T.let(
        ServiceTag.new(kind: 'object', name: name, description: description, metadata: metadata),
        T.untyped
      )
      @handlers = T.let({}, T::Hash[String, T.untyped])
    end

    sig { returns(String) }
    def name
      @service_tag.name
    end

    def service_name
      name
    end

    # Register a handler (instance-based API).
    def handler(name, kind: :exclusive, accept: 'application/json', content_type: 'application/json',
                input: nil, output: nil, &block)
      handler_io = HandlerIO.new(
        accept: accept, content_type: content_type,
        input_serde: Serde.resolve(input), output_serde: Serde.resolve(output)
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
