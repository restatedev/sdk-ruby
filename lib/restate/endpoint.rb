# typed: true
# frozen_string_literal: true

module Restate
  # Container for registered services. Bind services here, then create the Rack app.
  class Endpoint
    extend T::Sig

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :services

    sig { returns(T::Array[String]) }
    attr_reader :identity_keys

    sig { returns(T.nilable(String)) }
    attr_accessor :protocol

    sig { void }
    def initialize
      @services = T.let({}, T::Hash[String, T.untyped])
      @protocol = T.let(nil, T.nilable(String))
      @identity_keys = T.let([], T::Array[String])
    end

    # Bind one or more services to this endpoint.
    # Accepts both class-based services (e.g. +Counter+) and instance-based.
    #
    # @param svcs [Array<Class, Service, VirtualObject, Workflow>] services to bind
    # @return [self]
    # @raise [ArgumentError] if a service with the same name is already bound
    sig { params(svcs: T.untyped).returns(T.self_type) }
    def bind(*svcs)
      svcs.each do |svc|
        svc_name = svc.respond_to?(:service_name) ? svc.service_name : svc.name
        raise ArgumentError, "Service #{svc_name} already exists" if @services.key?(svc_name)

        @services[svc_name] = svc
      end
      self
    end

    # Force bidirectional streaming protocol.
    sig { returns(T.self_type) }
    def streaming_protocol
      @protocol = 'bidi'
      self
    end

    # Force request/response protocol.
    sig { returns(T.self_type) }
    def request_response_protocol
      @protocol = 'request_response'
      self
    end

    # Add an identity key for request verification.
    sig { params(key: String).returns(T.self_type) }
    def identity_key(key)
      @identity_keys << key
      self
    end

    # Build and return the Rack-compatible application.
    sig { returns(T.untyped) }
    def app
      require_relative 'server'
      Server.new(self)
    end
  end
end
