# typed: true
# frozen_string_literal: true

module Restate
  # A keyed virtual object with durable state.
  #
  # Class-based API (preferred):
  #   class Counter < Restate::VirtualObject
  #     # @param ctx [Restate::ObjectContext]
  #     handler def add(ctx, addend)
  #       old = ctx.get("count") || 0
  #       ctx.set("count", old + addend)
  #       old + addend
  #     end
  #
  #     # @param ctx [Restate::ObjectContext]
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

    # Register an exclusive handler. Use as: +handler def my_method(ctx, arg)+
    #
    # @param method_name [Symbol] name of the method to register
    # @param kind [Symbol] concurrency mode (+:exclusive+ or +:shared+)
    # @param opts [Hash] handler options (+input:+, +output:+, +accept:+, +content_type:+)
    # @return [Symbol] the method name
    def self.handler(method_name = nil, kind: :exclusive, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `handler def #{method_name}(...)` or `handler :#{method_name}`)"
      end
      return method_name unless method_name.is_a?(Symbol)

      _register_handler(method_name, **T.unsafe({ kind: kind.to_s, **opts }))
    end

    # Register a shared (concurrent-access) handler.
    #
    # @param method_name [Symbol] name of the method to register
    # @return [Symbol] the method name
    def self.shared(method_name, **opts)
      if method_name.is_a?(String)
        raise ArgumentError,
              "handler expects a Symbol (use `shared def #{method_name}(...)` or `shared :#{method_name}`)"
      end

      _register_handler(method_name, **T.unsafe({ kind: 'shared', **opts }))
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

    # Returns the service name.
    sig { returns(String) }
    def service_name
      name
    end

    # Register a handler on this instance-based virtual object.
    #
    # @param name [String] the handler name
    # @param kind [Symbol] concurrency mode (+:exclusive+ or +:shared+)
    # @param input [Class, #serialize, nil] type or serde for input deserialization
    # @param output [Class, #serialize, nil] type or serde for output serialization
    # @yield [ctx, input] the handler block
    # @return [self]
    def handler(name, kind: :exclusive, accept: 'application/json', content_type: 'application/json',
                input: nil, output: nil, &block)
      raise ArgumentError, 'handler requires a block' unless block

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
