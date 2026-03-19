# typed: true
# frozen_string_literal: true

require 'net/http'
require 'json'

module Restate
  # HTTP client for invoking Restate services from outside the Restate runtime.
  # Uses the Restate ingress HTTP API.
  #
  # @example Basic usage
  #   client = Restate::Client.new("http://localhost:8080")
  #
  #   # Stateless service
  #   result = client.service("Greeter").greet("World")
  #   result = client.service(Greeter).greet("World")
  #
  #   # Virtual object (keyed)
  #   result = client.object("Counter", "my-key").add(5)
  #   result = client.object(Counter, "my-key").get
  #
  #   # Workflow
  #   result = client.workflow("UserSignup", "user42").run("user@example.com")
  #
  # @example With custom headers
  #   client = Restate::Client.new("http://localhost:8080", headers: {
  #     "Authorization" => "Bearer token123"
  #   })
  class Client
    extend T::Sig

    sig { params(base_url: String, headers: T::Hash[String, String]).void }
    def initialize(base_url, headers: {})
      @base_url = base_url.chomp('/')
      @headers = headers
    end

    # Returns a proxy for calling a stateless service.
    #
    # @param service [String, Class] service name or class
    # @return [ClientServiceProxy]
    sig { params(service: T.any(String, T::Class[T.anything])).returns(ClientServiceProxy) }
    def service(service)
      ClientServiceProxy.new(@base_url, resolve_name(service), nil, @headers)
    end

    # Returns a proxy for calling a keyed virtual object.
    #
    # @param service [String, Class] service name or class
    # @param key [String] the object key
    # @return [ClientServiceProxy]
    sig { params(service: T.any(String, T::Class[T.anything]), key: String).returns(ClientServiceProxy) }
    def object(service, key)
      ClientServiceProxy.new(@base_url, resolve_name(service), key, @headers)
    end

    # Returns a proxy for calling a workflow.
    #
    # @param service [String, Class] service name or class
    # @param key [String] the workflow key
    # @return [ClientServiceProxy]
    sig { params(service: T.any(String, T::Class[T.anything]), key: String).returns(ClientServiceProxy) }
    def workflow(service, key)
      ClientServiceProxy.new(@base_url, resolve_name(service), key, @headers)
    end

    private

    sig { params(service: T.any(String, T::Class[T.anything])).returns(String) }
    def resolve_name(service)
      if service.is_a?(Class) && service.respond_to?(:service_name)
        T.unsafe(service).service_name
      else
        service.to_s
      end
    end
  end

  # Proxy that sends HTTP requests to the Restate ingress for a specific service.
  # Handler calls are forwarded via +method_missing+.
  #
  # @!visibility private
  class ClientServiceProxy
    extend T::Sig

    sig do
      params(base_url: String, service_name: String, key: T.nilable(String),
             headers: T::Hash[String, String]).void
    end
    def initialize(base_url, service_name, key, headers)
      @base_url = base_url
      @service_name = service_name
      @key = key
      @headers = headers
    end

    def method_missing(handler_name, arg = nil) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      path = @key ? "/#{@service_name}/#{@key}/#{handler_name}" : "/#{@service_name}/#{handler_name}"
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      @headers.each { |k, v| request[k] = v }
      request.body = JSON.generate(arg)
      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 read_timeout: 30) { |http| http.request(request) }
      Kernel.raise "Restate ingress error: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      body = response.body
      body && !body.empty? ? JSON.parse(body) : nil
    end

    def respond_to_missing?(_method_name, _include_private = false)
      true
    end
  end
end
