# typed: false
# frozen_string_literal: true

module Restate
  # Shared class-level DSL for defining Restate services via class inheritance.
  #
  # Extended into Service, VirtualObject, and Workflow. Provides the `handler`,
  # `shared`, `main`, and `service_name` class macros.
  #
  # Example:
  #   class Counter < Restate::VirtualObject
  #     handler def add(ctx, addend)
  #       old = ctx.get('counter') || 0
  #       ctx.set('counter', old + addend)
  #       old + addend
  #     end
  #   end
  module ServiceDSL
    def inherited(subclass)
      super
      subclass.instance_variable_set(:@_handler_registry, {})
      subclass.instance_variable_set(:@_service_name, nil)
      subclass.instance_variable_set(:@_handlers, nil)
    end

    # Get or set the service name. Defaults to the unqualified class name.
    def service_name(name = nil)
      if name
        @_service_name = name
      else
        @_service_name || self.name&.split('::')&.last
      end
    end

    # Returns the ServiceTag for this class-based service.
    # Subclasses (Service, VirtualObject, Workflow) must define `_service_kind`.
    def service_tag
      ServiceTag.new(kind: _service_kind, name: service_name)
    end

    # Returns a hash of handler name (String) => Handler struct.
    # Built lazily on first access and cached.
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

      @_handler_registry.each do |name, meta|
        handler_io = HandlerIO.new(
          accept: meta[:accept] || 'application/json',
          content_type: meta[:content_type] || 'application/json',
          input_serde: meta[:input_serde] || JsonSerde,
          output_serde: meta[:output_serde] || JsonSerde,
          input_schema: Restate.compute_json_schema(meta[:input_type]),
          output_schema: Restate.compute_json_schema(meta[:output_type])
        )

        um = instance_method(name)
        bound = um.bind(allocate)

        result[name] = Handler.new(
          service_tag: tag,
          handler_io: handler_io,
          kind: meta[:kind],
          name: name,
          callable: bound,
          arity: um.arity.abs
        )
      end

      result
    end
  end
end
