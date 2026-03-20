# frozen_string_literal: true

require 'net/http'
require 'json'

module Restate
  # HTTP client for invoking Restate services and managing the Restate runtime
  # from outside the Restate runtime.
  #
  # @example Via global config (recommended)
  #   Restate.configure do |c|
  #     c.ingress_url = "http://localhost:8080"
  #     c.admin_url = "http://localhost:9070"
  #   end
  #   client = Restate.client
  #   result = client.service(Greeter).greet("World")
  #
  # @example Standalone
  #   client = Restate::Client.new(ingress_url: "http://localhost:8080",
  #                                admin_url: "http://localhost:9070")
  #
  # @example Service invocation
  #   client.service("Greeter").greet("World")
  #   client.object("Counter", "my-key").add(5)
  #   client.workflow("UserSignup", "user42").run("user@example.com")
  #
  # @example Admin operations
  #   client.resolve_awakeable(awakeable_id, "result")
  #   client.reject_awakeable(awakeable_id, "failed")
  #   client.cancel_invocation(invocation_id)
  #   client.create_deployment("http://localhost:9080")
  class Client
    def initialize(ingress_url: 'http://localhost:8080', admin_url: 'http://localhost:9070',
                   ingress_headers: {}, admin_headers: {})
      @ingress_url = ingress_url.chomp('/')
      @admin_url = admin_url.chomp('/')
      @ingress_headers = ingress_headers
      @admin_headers = admin_headers
    end

    # ── Service invocation proxies ──

    # Returns a proxy for calling a stateless service.
    def service(service)
      ClientServiceProxy.new(@ingress_url, resolve_name(service), nil, @ingress_headers)
    end

    # Returns a proxy for calling a keyed virtual object.
    def object(service, key)
      ClientServiceProxy.new(@ingress_url, resolve_name(service), key, @ingress_headers)
    end

    # Returns a proxy for calling a workflow.
    def workflow(service, key)
      ClientServiceProxy.new(@ingress_url, resolve_name(service), key, @ingress_headers)
    end

    # ── Awakeable operations ──

    # Resolve an awakeable from outside the Restate runtime.
    def resolve_awakeable(awakeable_id, payload)
      post_ingress("/restate/awakeables/#{awakeable_id}/resolve", payload)
    end

    # Reject an awakeable from outside the Restate runtime.
    def reject_awakeable(awakeable_id, message, code: 500)
      post_ingress("/restate/awakeables/#{awakeable_id}/reject",
                   { 'message' => message, 'code' => code })
    end

    # ── Invocation management ──

    # Cancel a running invocation.
    def cancel_invocation(invocation_id)
      post_admin("/restate/invocations/#{invocation_id}/cancel", nil)
    end

    # Kill a running invocation (immediate termination, no cleanup).
    def kill_invocation(invocation_id)
      post_admin("/restate/invocations/#{invocation_id}/kill", nil)
    end

    private

    def resolve_name(service)
      if service.is_a?(Class) && service.respond_to?(:service_name)
        service.service_name
      else
        service.to_s
      end
    end

    def post_ingress(path, body) # rubocop:disable Metrics/AbcSize
      uri = URI("#{@ingress_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      @ingress_headers.each { |k, v| request[k] = v }
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 read_timeout: 30) { |http| http.request(request) }
      Kernel.raise "Restate ingress error: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      parse_response(response)
    end

    def post_admin(path, body) # rubocop:disable Metrics/AbcSize
      uri = URI("#{@admin_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      @admin_headers.each { |k, v| request[k] = v }
      request.body = JSON.generate(body) if body
      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 read_timeout: 30) { |http| http.request(request) }
      Kernel.raise "Restate admin error: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
      parse_response(response)
    end

    def parse_response(response)
      body = response.body
      body && !body.empty? ? JSON.parse(body) : nil
    end
  end

  # Proxy that sends HTTP requests to the Restate ingress for a specific service.
  # Handler calls are forwarded via +method_missing+.
  #
  # @!visibility private
  class ClientServiceProxy
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
