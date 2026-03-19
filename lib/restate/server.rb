# typed: true
# frozen_string_literal: true

require 'async'
require 'async/queue'
require 'logger'

module Restate
  # Rack-compatible application that handles Restate protocol requests.
  # Designed to work with Falcon for HTTP/2 bidirectional streaming.
  #
  # Routes:
  #   GET  /discover                     → service manifest
  #   GET  /health                       → health check
  #   POST /invoke/:service/:handler     → handler invocation
  class Server
    extend T::Sig

    SDK_VERSION = T.let(Internal::SDK_VERSION, String)
    X_RESTATE_SERVER = T.let("restate-sdk-ruby/#{SDK_VERSION}".freeze, String)

    LOGGER = T.let(Logger.new($stdout, progname: 'Restate::Server'), Logger)

    sig { params(endpoint: Endpoint).void }
    def initialize(endpoint)
      @endpoint = T.let(endpoint, Endpoint)
      @identity_verifier = T.let(Internal::IdentityVerifier.new(endpoint.identity_keys), Internal::IdentityVerifier)
    end

    # Rack interface
    sig { params(env: T::Hash[String, T.untyped]).returns(T.untyped) }
    def call(env)
      path = env['PATH_INFO'] || '/'
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
    rescue StandardError => e
      LOGGER.error("Exception in Restate server: #{e.inspect}")
      LOGGER.error(e.backtrace&.join("\n")) if e.backtrace
      error_response(500, 'Internal server error')
    end

    private

    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def parse_path(path)
      segments = path.split('/').reject(&:empty?)

      # Check for /invoke/:service/:handler
      if segments.length >= 3
        invoke_idx = segments.rindex('invoke')
        if invoke_idx && segments.length > invoke_idx + 2
          return {
            type: :invocation,
            service: segments[invoke_idx + 1],
            handler: segments[invoke_idx + 2]
          }
        end
      end

      case segments.last
      when 'health'
        { type: :health }
      when 'discover'
        { type: :discover }
      else
        { type: :unknown }
      end
    end

    sig { returns(T.untyped) }
    def health_response
      [200, { 'content-type' => 'application/json', 'x-restate-server' => X_RESTATE_SERVER }, ['{"status":"ok"}']]
    end

    sig { returns(T.untyped) }
    def not_found_response
      [404, { 'x-restate-server' => X_RESTATE_SERVER }, ['']]
    end

    sig { params(status: Integer, message: String).returns(T.untyped) }
    def error_response(status, message)
      [status, { 'content-type' => 'text/plain', 'x-restate-server' => X_RESTATE_SERVER }, [message]]
    end

    sig { params(env: T::Hash[String, T.untyped]).returns(T.untyped) }
    def handle_discover(env)
      # Detect HTTP version for protocol mode
      http_version = env['HTTP_VERSION'] || env['SERVER_PROTOCOL'] || 'HTTP/1.1'
      discovered_as = http_version.include?('2') ? 'bidi' : 'request_response'

      # Negotiate discovery protocol version from Accept header
      accept = env['HTTP_ACCEPT'] || ''
      version = negotiate_version(accept)
      return error_response(415, "Unsupported discovery version: #{accept}") unless version

      begin
        json = Discovery.compute_discovery_json(@endpoint, version, discovered_as)
        content_type = "application/vnd.restate.endpointmanifest.v#{version}+json"
        [
          200,
          {
            'content-type' => content_type,
            'x-restate-server' => X_RESTATE_SERVER
          },
          [json]
        ]
      rescue StandardError => e
        error_response(500, "Error computing discovery: #{e.message}")
      end
    end

    sig { params(accept: String).returns(T.nilable(Integer)) }
    def negotiate_version(accept)
      if accept.include?('application/vnd.restate.endpointmanifest.v4+json')
        4
      elsif accept.include?('application/vnd.restate.endpointmanifest.v3+json')
        3
      elsif accept.include?('application/vnd.restate.endpointmanifest.v2+json')
        2
      elsif accept.empty?
        2
      end
    end

    sig { params(env: T::Hash[String, T.untyped], service_name: T.untyped, handler_name: T.untyped).returns(T.untyped) }
    def handle_invocation(env, service_name, handler_name)
      # Verify identity
      request_headers = extract_headers(env)
      path = env['PATH_INFO'] || '/'
      begin
        @identity_verifier.verify(request_headers, path)
      rescue Internal::IdentityVerificationError
        return [401, { 'x-restate-server' => X_RESTATE_SERVER }, ['']]
      end

      # Find the service and handler
      service = @endpoint.services[service_name]
      return not_found_response unless service

      handler = service.handlers[handler_name]
      return not_found_response unless handler

      # Process the invocation with streaming
      process_invocation(env, handler, request_headers)
    end

    sig { params(env: T::Hash[String, T.untyped], handler: T.untyped, request_headers: T.untyped).returns(T.untyped) }
    def process_invocation(env, handler, request_headers)
      vm = VMWrapper.new(request_headers)
      status, response_headers = vm.get_response_head

      # Streaming response body — output chunks are sent to Restate as they're
      # produced. This is critical for BidiStream mode where the VM needs output
      # acknowledged before it can make further progress.
      output_queue = Async::Queue.new
      send_output = ->(chunk) { output_queue.enqueue(chunk) }

      # Input queue bridges the HTTP body reader and the handler's progress loop.
      input_queue = Async::Queue.new

      # Read request body chunks and feed to VM until ready to execute,
      # then continue feeding remaining chunks via the input queue.
      rack_input = env['rack.input']
      ready = T.let(false, T::Boolean)
      if rack_input
        # Feed chunks until the VM has enough to start execution
        while (chunk = rack_input.read_partial(16_384))
          vm.notify_input(chunk.b) unless chunk.empty?
          if vm.is_ready_to_execute
            ready = true
            break
          end
        end
        vm.notify_input_closed unless ready
      end

      invocation = vm.sys_input

      # Spawn a background task to continue reading remaining input
      if ready
        Async do
          while (chunk = rack_input.read_partial(16_384))
            input_queue.enqueue(chunk.b) unless chunk.empty?
          end
          input_queue.enqueue(:eof)
        rescue StandardError => e
          LOGGER.error("Input reader error: #{e.inspect}")
          input_queue.enqueue(:disconnected)
        end
      end

      context = ServerContext.new(
        vm: vm,
        handler: handler,
        invocation: invocation,
        send_output: send_output,
        input_queue: input_queue,
        middleware: @endpoint.middleware
      )

      # Spawn the handler as an async task so the response body can stream
      # output concurrently.
      Async do
        begin
          context.enter
        rescue DisconnectedError
          # Client disconnected
        rescue StandardError => e
          LOGGER.error("Exception in handler: #{e.inspect}")
        ensure
          # Signal that the attempt is finished — wakes any waiters on
          # ctx.request.attempt_finished_event and cancels pending background pool jobs.
          context.on_attempt_finished
        end

        # Drain remaining output from VM
        loop do
          chunk = vm.take_output
          break if chunk.nil? || chunk.empty?

          output_queue.enqueue(chunk)
        end

        # Signal end of output
        output_queue.enqueue(nil)
      end

      body = StreamingBody.new(output_queue)

      merged_headers = response_headers.to_h { |pair| [pair[0], pair[1]] }
      merged_headers['x-restate-server'] = X_RESTATE_SERVER

      [status, merged_headers, body]
    end

    # Rack 3 streaming body that yields chunks from an Async::Queue.
    # Terminates when nil is dequeued.
    class StreamingBody
      extend T::Sig

      sig { params(queue: Async::Queue).void }
      def initialize(queue)
        @queue = T.let(queue, Async::Queue)
      end

      def each
        loop do
          chunk = @queue.dequeue
          break if chunk.nil?

          yield chunk
        end
      end
    end

    sig { params(env: T::Hash[String, T.untyped]).returns(T::Array[T::Array[String]]) }
    def extract_headers(env)
      headers = T.let([], T::Array[T::Array[String]])
      env.each do |key, value|
        next unless key.start_with?('HTTP_')

        header_name = key.sub('HTTP_', '').tr('_', '-').downcase
        headers << [header_name, value]
      end
      # Also include content-type and content-length if present
      headers << ['content-type', env['CONTENT_TYPE']] if env['CONTENT_TYPE']
      headers << ['content-length', env['CONTENT_LENGTH']] if env['CONTENT_LENGTH']
      headers
    end
  end
end
