# typed: true
# frozen_string_literal: true

module Restate
  # Container for registered services. Bind services here, then create the Rack app.
  class Endpoint
    attr_reader :services, :identity_keys, :middleware

    attr_accessor :protocol

    def initialize
      @services = {}
      @protocol = nil
      @identity_keys = []
      @middleware = []
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

    # Add handler-level middleware.
    #
    # Middleware wraps every handler invocation with access to the handler metadata
    # and context. Use it for tracing, metrics, logging, error reporting, etc.
    #
    # A middleware is a class whose instances respond to +call(handler, ctx)+.
    # Use +yield+ inside +call+ to invoke the next middleware or the handler.
    # The return value of +yield+ is the handler's return value.
    #
    # This follows the same pattern as {https://github.com/sidekiq/sidekiq/wiki/Middleware Sidekiq middleware}.
    #
    # @example OpenTelemetry tracing
    #   class OpenTelemetryMiddleware
    #     def call(handler, ctx)
    #       tracer.in_span(handler.name, attributes: {
    #         'restate.service' => handler.service_tag.name,
    #         'restate.invocation_id' => ctx.request.id
    #       }) do
    #         yield
    #       end
    #     end
    #   end
    #   endpoint.use(OpenTelemetryMiddleware)
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
    # @example Middleware with configuration
    #   class AuthMiddleware
    #     def initialize(api_key:)
    #       @api_key = api_key
    #     end
    #
    #     def call(handler, ctx)
    #       raise Restate::TerminalError.new('unauthorized', status_code: 401) unless valid?(ctx)
    #       yield
    #     end
    #   end
    #   endpoint.use(AuthMiddleware, api_key: 'secret')
    #
    # @param klass [Class] middleware class (will be instantiated by the SDK)
    # @param args [Array] positional arguments for the middleware constructor
    # @param kwargs [Hash] keyword arguments for the middleware constructor
    # @return [self]
    def use(klass, *args, **kwargs)
      instance = if kwargs.empty?
                   klass.new(*args)
                 else
                   klass.new(*args, **kwargs)
                 end
      @middleware << instance
      self
    end

    # Build and return the Rack-compatible application.
    def app
      require_relative 'server'
      Server.new(self)
    end
  end
end
