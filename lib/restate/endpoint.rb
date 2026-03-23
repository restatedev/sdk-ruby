# typed: true
# frozen_string_literal: true

module Restate
  # Container for registered services. Bind services here, then create the Rack app.
  class Endpoint
    attr_reader :services, :identity_keys, :middleware, :outbound_middleware

    attr_accessor :protocol

    def initialize
      @services = {}
      @protocol = nil
      @identity_keys = []
      @middleware = []
      @outbound_middleware = []
    end

    # Bind one or more services to this endpoint.
    #
    # @param svcs [Array<Class<Service>, Class<VirtualObject>, Class<Workflow>>] services to bind
    # @return [self]
    # @raise [ArgumentError] if a service with the same name is already bound
    def bind(*svcs)
      svcs.each do |svc|
        svc_name = svc.service_name
        raise ArgumentError, "Service #{svc_name} already exists" if @services.key?(svc_name)

        @services[svc_name] = svc
      end
      self
    end

    # Force bidirectional streaming protocol.
    def streaming_protocol
      @protocol = 'bidi'
      self
    end

    # Force request/response protocol.
    def request_response_protocol
      @protocol = 'request_response'
      self
    end

    # Add an identity key for request verification.
    def identity_key(key)
      @identity_keys << key
      self
    end

    # Add inbound (server) middleware.
    #
    # Inbound middleware wraps every handler invocation, like
    # {https://github.com/sidekiq/sidekiq/wiki/Middleware Sidekiq server middleware}.
    #
    # A middleware is a class whose instances respond to +call(handler, ctx)+.
    # Use +yield+ inside +call+ to invoke the next middleware or the handler.
    # The return value of +yield+ is the handler's return value.
    #
    # @example OpenTelemetry tracing
    #   class TracingMiddleware
    #     def call(handler, ctx)
    #       extracted = OpenTelemetry.propagation.extract(ctx.request.headers)
    #       OpenTelemetry::Context.with_current(extracted) do
    #         tracer.in_span(handler.name) { yield }
    #       end
    #     end
    #   end
    #   endpoint.use(TracingMiddleware)
    #
    # @example Metrics
    #   class MetricsMiddleware
    #     def call(handler, ctx)
    #       start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    #       result = yield
    #       duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    #       StatsD.timing("restate.handler.#{handler.name}", duration)
    #       result
    #     end
    #   end
    #   endpoint.use(MetricsMiddleware)
    #
    # @param klass [Class] middleware class (will be instantiated by the SDK)
    # @param args [Array] positional arguments for the middleware constructor
    # @param kwargs [Hash] keyword arguments for the middleware constructor
    # @return [self]
    def use(klass, *args, **kwargs)
      @middleware << instantiate_middleware(klass, args, kwargs)
      self
    end

    # Add outbound (client) middleware.
    #
    # Outbound middleware wraps every outgoing service call and send, like
    # {https://github.com/sidekiq/sidekiq/wiki/Middleware Sidekiq client middleware}.
    #
    # A middleware is a class whose instances respond to +call(service, handler, headers)+.
    # The +headers+ hash is mutable — modify it to attach headers to the outgoing
    # request. Use +yield+ to continue the chain.
    #
    # Note: Restate automatically propagates inbound headers to outbound calls.
    # Outbound middleware is for injecting *new* headers that aren't on the
    # original request (e.g., tenant IDs from fiber-local storage, authorization
    # tokens for specific target services).
    #
    # @example Propagate tenant ID to all outgoing calls
    #   class TenantOutboundMiddleware
    #     def call(_service, _handler, headers)
    #       headers['x-tenant-id'] = Thread.current[:tenant_id]
    #       yield
    #     end
    #   end
    #   endpoint.use_outbound(TenantOutboundMiddleware)
    #
    # @example Log all outgoing calls
    #   class OutboundLogger
    #     def call(service, handler, headers)
    #       logger.info("Calling #{service}/#{handler}")
    #       yield
    #     end
    #   end
    #   endpoint.use_outbound(OutboundLogger)
    #
    # @param klass [Class] middleware class (will be instantiated by the SDK)
    # @param args [Array] positional arguments for the middleware constructor
    # @param kwargs [Hash] keyword arguments for the middleware constructor
    # @return [self]
    def use_outbound(klass, *args, **kwargs)
      @outbound_middleware << instantiate_middleware(klass, args, kwargs)
      self
    end

    # Build and return the Rack-compatible application.
    def app
      require_relative 'server'
      Server.new(self)
    end

    private

    def instantiate_middleware(klass, args, kwargs)
      if kwargs.empty?
        klass.new(*args)
      else
        klass.new(*args, **kwargs)
      end
    end
  end
end
