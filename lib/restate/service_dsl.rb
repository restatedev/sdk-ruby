# typed: true
# frozen_string_literal: true

module Restate
  # Shared class-level DSL for defining Restate services via class inheritance.
  #
  # Extended into Service, VirtualObject, and Workflow. Provides the +handler+,
  # +shared+, +main+, and +service_name+ class macros.
  #
  # @example
  #   class Counter < Restate::VirtualObject
  #     handler def add(addend)
  #       ctx = Restate.current_object_context
  #       old = ctx.get('counter') || 0
  #       ctx.set('counter', old + addend)
  #       old + addend
  #     end
  #   end
  module ServiceDSL
    # Called when a subclass is created; initializes the handler registry.
    def inherited(subclass)
      super
      subclass.instance_variable_set(:@_handler_registry, {})
      subclass.instance_variable_set(:@_service_name, nil)
      subclass.instance_variable_set(:@_handlers, nil)
    end

    # Get or set the service name. Defaults to the unqualified class name.
    #
    # @param name [String, nil] when provided, sets the service name
    # @return [String] the current service name
    def service_name(name = nil)
      if name
        @_service_name = name
      else
        @_service_name || T.unsafe(self).name&.split('::')&.last
      end
    end

    # Returns the ServiceTag for this class-based service.
    # Subclasses must define +_service_kind+.
    #
    # @return [ServiceTag]
    def service_tag
      ServiceTag.new(kind: T.unsafe(self)._service_kind, name: service_name)
    end

    # Returns a hash of handler name (String) to Handler.
    # Built lazily on first access and cached.
    #
    # @return [Hash{String => Handler}]
    def handlers
      @_handlers ||= _build_handlers # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    private

    # Store handler metadata for later building.
    def _register_handler(method_name, kind:, **opts)
      @_handlers = nil # invalidate cache
      @_handler_registry[method_name.to_s] = { kind: kind, **opts }
      method_name
    end

    # Build Handler structs from the registry using instance_method + bind.
    def _build_handlers # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      tag = service_tag
      result = {}
      instance = T.unsafe(self).allocate

      @_handler_registry.each do |name, meta|
        input_serde = Serde.resolve(meta[:input])
        output_serde = Serde.resolve(meta[:output])

        handler_io = HandlerIO.new(
          accept: meta[:accept] || 'application/json',
          content_type: meta[:content_type] || 'application/json',
          input_serde: input_serde,
          output_serde: output_serde
        )

        um = T.unsafe(self).instance_method(name)
        arity = um.arity.abs
        unless [0, 1].include?(arity)
          Kernel.raise ArgumentError, "handler '#{name}' must accept 0 or 1 parameters ([input]), got #{arity}"
        end

        bound = um.bind(instance)

        result[name] = Handler.new(
          service_tag: tag,
          handler_io: handler_io,
          kind: meta[:kind],
          name: name,
          callable: bound,
          arity: arity
        )
      end

      result
    end
  end
end
