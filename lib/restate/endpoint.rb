# frozen_string_literal: true

module Restate
  # Container for registered services. Bind services here, then create the Rack app.
  class Endpoint
    attr_reader :services, :identity_keys
    attr_accessor :protocol

    def initialize
      @services = {}
      @protocol = nil
      @identity_keys = []
    end

    # Bind one or more services to this endpoint.
    def bind(*svcs)
      svcs.each do |svc|
        raise ArgumentError, "Service #{svc.name} already exists" if @services.key?(svc.name)
        unless svc.is_a?(Service) || svc.is_a?(VirtualObject) || svc.is_a?(Workflow)
          raise ArgumentError, "Invalid service type: #{svc.class}"
        end

        @services[svc.name] = svc
      end
      self
    end

    # Force bidirectional streaming protocol.
    def streaming_protocol
      @protocol = "bidi"
      self
    end

    # Force request/response protocol.
    def request_response_protocol
      @protocol = "request_response"
      self
    end

    # Add an identity key for request verification.
    def identity_key(key)
      @identity_keys << key
      self
    end

    # Build and return the Rack-compatible application.
    def app
      require_relative "server"
      Server.new(self)
    end
  end
end
