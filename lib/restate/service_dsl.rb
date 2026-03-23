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
  #     handler def add(ctx, addend)
  #       old = ctx.get('counter') || 0
  #       ctx.set('counter', old + addend)
  #       old + addend
  #     end
  #   end
  module ServiceDSL # rubocop:disable Metrics/ModuleLength
    # Called when a subclass is created; initializes the handler registry.
    def inherited(subclass) # rubocop:disable Metrics/MethodLength
      super
      subclass.instance_variable_set(:@_handler_registry, {})
      subclass.instance_variable_set(:@_service_name, nil)
      subclass.instance_variable_set(:@_handlers, nil)
      subclass.instance_variable_set(:@_enable_lazy_state, nil)
      subclass.instance_variable_set(:@_description, nil)
      subclass.instance_variable_set(:@_metadata, nil)
      subclass.instance_variable_set(:@_inactivity_timeout, nil)
      subclass.instance_variable_set(:@_abort_timeout, nil)
      subclass.instance_variable_set(:@_journal_retention, nil)
      subclass.instance_variable_set(:@_idempotency_retention, nil)
      subclass.instance_variable_set(:@_ingress_private, nil)
      subclass.instance_variable_set(:@_invocation_retry_policy, nil)
      subclass.instance_variable_set(:@_state_declarations, {})
    end

    # Declare a durable state entry with auto-generated getter, setter, and clear methods.
    # Only available on VirtualObject and Workflow.
    #
    # The generated methods delegate to the current Restate context via +Thread.current+
    # (fiber-scoped in Ruby 3.0+), so they work correctly across concurrent invocations.
    #
    # @param name [Symbol] state key name
    # @param default [Object, nil] default value returned when state is not set
    # @param serde [Object] serializer/deserializer (defaults to JsonSerde)
    #
    # @example
    #   class Counter < Restate::VirtualObject
    #     state :count, default: 0
    #
    #     handler def add(ctx, addend)
    #       self.count += addend  # reads then writes via ctx.get/ctx.set
    #     end
    #
    #     shared def get(ctx)
    #       count  # reads via ctx.get, returns 0 if unset
    #     end
    #   end
    def state(name, default: nil, serde: nil) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      unless respond_to?(:_service_kind) && %w[object workflow].include?(_service_kind)
        Kernel.raise ArgumentError, 'state declarations are only available on VirtualObject and Workflow'
      end

      name = name.to_sym
      @_state_declarations[name] = { default: default, serde: serde }
      state_key = name.to_s
      state_serde = serde
      state_default = default

      # Getter: reads from durable state, returns default if unset
      define_method(name) do
        ctx = Thread.current[:restate_context]
        Kernel.raise 'Not inside a Restate handler' unless ctx

        val = state_serde ? ctx.get(state_key, serde: state_serde) : ctx.get(state_key)
        val.nil? ? state_default : val
      end

      # Setter: writes to durable state
      define_method(:"#{name}=") do |value|
        ctx = Thread.current[:restate_context]
        Kernel.raise 'Not inside a Restate handler' unless ctx

        if state_serde
          ctx.set(state_key, value, serde: state_serde)
        else
          ctx.set(state_key, value)
        end
      end

      # Clear: removes the state entry
      define_method(:"clear_#{name}") do
        ctx = Thread.current[:restate_context]
        Kernel.raise 'Not inside a Restate handler' unless ctx

        ctx.clear(state_key)
      end
    end

    # Get or set the service name. Defaults to the unqualified class name.
    #
    # @param name [String, nil] when provided, sets the service name
    # @return [String] the current service name
    def service_name(name = nil)
      if name
        @_service_name = name
      else
        @_service_name ||= self.name&.split('::')&.last # rubocop:disable Naming/MemoizedInstanceVariableName
      end
    end

    # Enable lazy state loading for all handlers in this service.
    # When enabled, state is fetched on demand rather than pre-loaded.
    #
    # @param value [Boolean] whether to enable lazy state
    def enable_lazy_state(value = true) # rubocop:disable Style/OptionalBooleanParameter
      @_enable_lazy_state = value
    end

    # Set or get a human-readable description for this service.
    #
    # @param text [String, nil] when provided, sets the description
    # @return [String, nil] the current description
    def description(text = nil)
      if text
        @_description = text
      else
        @_description
      end
    end

    # Set or get metadata for this service.
    #
    # @param hash [Hash, nil] when provided, sets the metadata
    # @return [Hash, nil] the current metadata
    def metadata(hash = nil)
      if hash
        @_metadata = hash
      else
        @_metadata
      end
    end

    # Set the inactivity timeout (in seconds) for this service.
    #
    # @param seconds [Numeric] timeout in seconds
    def inactivity_timeout(seconds)
      @_inactivity_timeout = seconds
    end

    # Set the abort timeout (in seconds) for this service.
    #
    # @param seconds [Numeric] timeout in seconds
    def abort_timeout(seconds)
      @_abort_timeout = seconds
    end

    # Set the journal retention (in seconds) for this service.
    #
    # @param seconds [Numeric] retention in seconds
    def journal_retention(seconds)
      @_journal_retention = seconds
    end

    # Set the idempotency retention (in seconds) for this service.
    #
    # @param seconds [Numeric] retention in seconds
    def idempotency_retention(seconds)
      @_idempotency_retention = seconds
    end

    # Mark this service as private to the ingress.
    #
    # @param value [Boolean] whether the service is ingress-private
    def ingress_private(value = true) # rubocop:disable Style/OptionalBooleanParameter
      @_ingress_private = value
    end

    # Set the invocation retry policy for this service.
    #
    # @param initial_interval [Numeric, nil] initial retry interval in seconds
    # @param max_interval [Numeric, nil] maximum retry interval in seconds
    # @param max_attempts [Integer, nil] maximum number of retry attempts
    # @param exponentiation_factor [Numeric, nil] backoff exponentiation factor
    # @param on_max_attempts [Symbol, String, nil] action on max attempts (:pause or :kill)
    def invocation_retry_policy(initial_interval: nil, max_interval: nil, max_attempts: nil,
                                exponentiation_factor: nil, on_max_attempts: nil)
      @_invocation_retry_policy = {
        initial_interval: initial_interval,
        max_interval: max_interval,
        max_attempts: max_attempts,
        exponentiation_factor: exponentiation_factor,
        on_max_attempts: on_max_attempts
      }.compact
    end

    # Returns the ServiceTag for this class-based service.
    # Subclasses must define +_service_kind+.
    #
    # @return [ServiceTag]
    def service_tag
      ServiceTag.new(kind: _service_kind, name: service_name,
                     description: @_description, metadata: @_metadata)
    end

    # Returns the service-level lazy state setting (nil if not set).
    def lazy_state?
      @_enable_lazy_state
    end

    # Returns the service-level inactivity timeout (nil if not set).
    def svc_inactivity_timeout
      @_inactivity_timeout
    end

    # Returns the service-level abort timeout (nil if not set).
    def svc_abort_timeout
      @_abort_timeout
    end

    # Returns the service-level journal retention (nil if not set).
    def svc_journal_retention
      @_journal_retention
    end

    # Returns the service-level idempotency retention (nil if not set).
    def svc_idempotency_retention
      @_idempotency_retention
    end

    # Returns the service-level ingress private setting (nil if not set).
    def svc_ingress_private
      @_ingress_private
    end

    # Returns the service-level invocation retry policy (nil if not set).
    def svc_invocation_retry_policy
      @_invocation_retry_policy
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
      instance = allocate

      @_handler_registry.each do |name, meta| # rubocop:disable Metrics/BlockLength
        input_serde = Serde.resolve(meta[:input])
        output_serde = Serde.resolve(meta[:output])

        handler_io = HandlerIO.new(
          accept: meta[:accept] || 'application/json',
          content_type: meta[:content_type] || 'application/json',
          input_serde: input_serde,
          output_serde: output_serde
        )

        um = instance_method(name)
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
          arity: arity,
          enable_lazy_state: meta[:enable_lazy_state],
          description: meta[:description],
          metadata: meta[:metadata],
          inactivity_timeout: meta[:inactivity_timeout],
          abort_timeout: meta[:abort_timeout],
          journal_retention: meta[:journal_retention],
          idempotency_retention: meta[:idempotency_retention],
          workflow_completion_retention: meta[:workflow_completion_retention],
          ingress_private: meta[:ingress_private],
          invocation_retry_policy: meta[:invocation_retry_policy]
        )
      end

      result
    end
  end
end
