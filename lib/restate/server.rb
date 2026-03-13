# frozen_string_literal: true

require "async"
require "async/queue"
require "logger"

module Restate
  # Rack-compatible application that handles Restate protocol requests.
  # Designed to work with Falcon for HTTP/2 bidirectional streaming.
  #
  # Routes:
  #   GET  /discover                     → service manifest
  #   GET  /health                       → health check
  #   POST /invoke/:service/:handler     → handler invocation
  class Server
    SDK_VERSION = Internal::SDK_VERSION
    X_RESTATE_SERVER = "restate-sdk-ruby/#{SDK_VERSION}"

    LOGGER = Logger.new($stdout, progname: "Restate::Server")

    def initialize(endpoint)
      @endpoint = endpoint
      @identity_verifier = Internal::IdentityVerifier.new(endpoint.identity_keys)
    end

    # Rack interface
    def call(env)
      path = env["PATH_INFO"] || "/"
      parsed = parse_path(path)

      case parsed[:type]
      when :health
        health_response
      when :discover
        handle_discover(env)
      when :invocation
        handle_invocation(env, parsed[:service], parsed[:handler])
      else
        not_found_response
      end
    rescue => e
      LOGGER.error("Exception in Restate server: #{e.inspect}")
      LOGGER.error(e.backtrace&.join("\n")) if e.backtrace
      error_response(500, "Internal server error")
    end

    private

    def parse_path(path)
      segments = path.split("/").reject(&:empty?)

      # Check for /invoke/:service/:handler
      if segments.length >= 3
        invoke_idx = segments.rindex("invoke")
        if invoke_idx && segments.length > invoke_idx + 2
          return {
            type: :invocation,
            service: segments[invoke_idx + 1],
            handler: segments[invoke_idx + 2]
          }
        end
      end

      case segments.last
      when "health"
        { type: :health }
      when "discover"
        { type: :discover }
      else
        { type: :unknown }
      end
    end

    def health_response
      [200, { "content-type" => "application/json", "x-restate-server" => X_RESTATE_SERVER }, ['{"status":"ok"}']]
    end

    def not_found_response
      [404, { "x-restate-server" => X_RESTATE_SERVER }, [""]]
    end

    def error_response(status, message)
      [status, { "content-type" => "text/plain", "x-restate-server" => X_RESTATE_SERVER }, [message]]
    end

    def handle_discover(env)
      # Detect HTTP version for protocol mode
      http_version = env["HTTP_VERSION"] || env["SERVER_PROTOCOL"] || "HTTP/1.1"
      discovered_as = http_version.include?("2") ? "bidi" : "request_response"

      # Negotiate discovery protocol version from Accept header
      accept = env["HTTP_ACCEPT"] || ""
      version = negotiate_version(accept)
      return error_response(415, "Unsupported discovery version: #{accept}") unless version

      begin
        json = Discovery.compute_discovery_json(@endpoint, version, discovered_as)
        content_type = "application/vnd.restate.endpointmanifest.v#{version}+json"
        [
          200,
          {
            "content-type" => content_type,
            "x-restate-server" => X_RESTATE_SERVER
          },
          [json]
        ]
      rescue => e
        error_response(500, "Error computing discovery: #{e.message}")
      end
    end

    def negotiate_version(accept)
      if accept.include?("application/vnd.restate.endpointmanifest.v4+json")
        4
      elsif accept.include?("application/vnd.restate.endpointmanifest.v3+json")
        3
      elsif accept.include?("application/vnd.restate.endpointmanifest.v2+json")
        2
      elsif accept.empty?
        2
      end
    end

    def handle_invocation(env, service_name, handler_name)
      # Verify identity
      request_headers = extract_headers(env)
      path = env["PATH_INFO"] || "/"
      begin
        @identity_verifier.verify(request_headers, path)
      rescue Internal::IdentityVerificationError
        return [401, { "x-restate-server" => X_RESTATE_SERVER }, [""]]
      end

      # Find the service and handler
      service = @endpoint.services[service_name]
      return not_found_response unless service

      handler = service.handlers[handler_name]
      return not_found_response unless handler

      # Process the invocation with streaming
      process_invocation(env, handler, request_headers)
    end

    def process_invocation(env, handler, request_headers)
      vm = VMWrapper.new(request_headers)
      status, response_headers = vm.get_response_head

      # Read request body and feed to VM
      input_body = env["rack.input"]
      if input_body
        body_content = input_body.read
        if body_content && !body_content.empty?
          vm.notify_input(body_content.b)
        end
      end
      vm.notify_input_closed

      # Execute the handler
      invocation = vm.sys_input

      # For non-streaming (HTTP/1.1 request-response), we use a simple buffer
      output_chunks = []
      send_output = ->(chunk) { output_chunks << chunk }

      # Create a dummy input queue (input already fully read)
      input_queue = Queue.new
      input_queue << :eof

      context = ServerContext.new(
        vm: vm,
        handler: handler,
        invocation: invocation,
        send_output: send_output,
        input_queue: input_queue
      )

      begin
        context.enter
      rescue DisconnectedError
        # Client disconnected
      rescue => e
        LOGGER.error("Exception in handler: #{e.inspect}")
      end

      # Collect remaining output
      loop do
        chunk = vm.take_output
        break unless chunk
        output_chunks << chunk
      end

      merged_headers = response_headers.map { |pair| [pair[0], pair[1]] }.to_h
      merged_headers["x-restate-server"] = X_RESTATE_SERVER

      [status, merged_headers, output_chunks]
    end

    def extract_headers(env)
      headers = []
      env.each do |key, value|
        next unless key.start_with?("HTTP_")

        header_name = key.sub("HTTP_", "").tr("_", "-").downcase
        headers << [header_name, value]
      end
      # Also include content-type and content-length if present
      headers << ["content-type", env["CONTENT_TYPE"]] if env["CONTENT_TYPE"]
      headers << ["content-length", env["CONTENT_LENGTH"]] if env["CONTENT_LENGTH"]
      headers
    end
  end
end
