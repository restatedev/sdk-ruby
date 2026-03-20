# frozen_string_literal: true

require 'restate'
require 'socket'
require 'net/http'
require 'json'
require 'uri'
require 'testcontainers'

module Restate
  # Test harness for running Restate services with a real Restate server.
  # Opt-in via `require "restate/testing"` (not loaded by default).
  #
  # Requires Docker and the testcontainers-core gem.
  #
  # Block-based (recommended):
  #   Restate::Testing.start(Greeter, Counter) do |env|
  #     env.ingress_url  # => "http://localhost:32771"
  #     env.admin_url    # => "http://localhost:32772"
  #   end
  #
  # Manual lifecycle (for RSpec before/after hooks):
  #   harness = Restate::Testing::RestateTestHarness.new(Greeter, Counter)
  #   harness.start
  #   harness.ingress_url
  #   harness.stop
  module Testing
    # Starts a Restate test environment with the given services.
    # When a block is given, stops automatically on block exit.
    # Without a block, returns the harness for manual lifecycle management.
    def self.start(*services, **options)
      harness = RestateTestHarness.new(*services, **options)
      harness.start

      if block_given?
        begin
          yield harness
        ensure
          harness.stop
        end
      else
        harness
      end
    end

    # Manages the lifecycle of an SDK server and a Restate container for testing.
    class RestateTestHarness
      attr_reader :ingress_url, :admin_url

      # @param services [Array<Class>] Service classes to register.
      # @param restate_image [String] Docker image for Restate server.
      # @param always_replay [Boolean] Force replay on every suspension point.
      # @param disable_retries [Boolean] Disable Restate retry policy.
      # @yield [Endpoint] Optional block to configure the endpoint (e.g. add middleware).
      def initialize(*services,
                     restate_image: 'docker.io/restatedev/restate:latest',
                     always_replay: false,
                     disable_retries: false,
                     &configure)
        @services = services
        @restate_image = restate_image
        @always_replay = always_replay
        @disable_retries = disable_retries
        @configure = configure
        @server_thread = nil
        @container = nil
        @port = nil
        @ingress_url = nil
        @admin_url = nil
      end

      def start
        @port = find_free_port
        endpoint = Restate.endpoint(*@services)
        @configure&.call(endpoint)
        rack_app = endpoint.app
        start_sdk_server(rack_app)
        wait_for_tcp(@port)
        start_restate_container
        register_sdk
        self
      rescue StandardError => e
        stop
        raise e
      end

      def stop
        stop_restate_container
        stop_sdk_server
      end

      private

      def find_free_port
        server = TCPServer.new('0.0.0.0', 0)
        port = server.addr[1]
        server.close
        port
      end

      def start_sdk_server(rack_app)
        require 'async'
        require 'async/http/endpoint'
        require 'falcon/server'

        port = @port
        ready = Queue.new

        @server_thread = Thread.new do
          Async do
            endpoint = Async::HTTP::Endpoint.parse("http://0.0.0.0:#{port}")
            middleware = Falcon::Server.middleware(rack_app, cache: false)
            server = Falcon::Server.new(middleware, endpoint)
            ready.push(true)
            server.run
          end
        end

        ready.pop
      end

      def wait_for_tcp(port, timeout: 10)
        deadline = Time.now + timeout
        loop do
          TCPSocket.new('127.0.0.1', port).close
          return
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET
          raise "SDK server failed to start on port #{port} within #{timeout}s" if Time.now > deadline

          sleep 0.1
        end
      end

      def start_restate_container
        env = {
          'RESTATE_LOG_FILTER' => 'restate=info',
          'RESTATE_BOOTSTRAP_NUM_PARTITIONS' => '1',
          'RESTATE_DEFAULT_NUM_PARTITIONS' => '1',
          'RESTATE_SHUTDOWN_TIMEOUT' => '10s',
          'RESTATE_ROCKSDB_TOTAL_MEMORY_SIZE' => '32 MB',
          'RESTATE_WORKER__INVOKER__IN_MEMORY_QUEUE_LENGTH_LIMIT' => '64',
          'RESTATE_WORKER__INVOKER__INACTIVITY_TIMEOUT' => @always_replay ? '0s' : '10m',
          'RESTATE_WORKER__INVOKER__ABORT_TIMEOUT' => '10m'
        }
        env['RESTATE_WORKER__INVOKER__RETRY_POLICY__TYPE'] = 'none' if @disable_retries

        @container = RestateContainer.new(@restate_image)
        @container.with_exposed_ports(8080, 9070)
        @container.with_env(env)
        @container.start

        @container.wait_for_http(path: '/restate/health', container_port: 8080, status: 200, timeout: 30)
        @container.wait_for_http(path: '/health', container_port: 9070, status: 200, timeout: 30)

        @ingress_url = "http://#{@container.host}:#{@container.mapped_port(8080)}"
        @admin_url = "http://#{@container.host}:#{@container.mapped_port(9070)}"
      end

      def register_sdk
        uri = URI("#{@admin_url}/deployments")
        sdk_url = "http://host.docker.internal:#{@port}"

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate({ uri: sdk_url })

        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        return if response.code.start_with?('2')

        raise "Failed to register SDK at #{sdk_url}: #{response.code} #{response.body}"
      end

      def stop_restate_container
        return unless @container

        @container.stop!
        @container.remove(force: true)
      rescue StandardError
        # Ignore cleanup errors
      end

      def stop_sdk_server
        @server_thread&.kill
        @server_thread&.join(5)
      end
    end

    # Testcontainers::DockerContainer subclass that adds ExtraHosts support
    # so the Restate container can reach the host-bound SDK server.
    class RestateContainer < Testcontainers::DockerContainer
      private

      def _container_create_options
        options = super
        options['HostConfig'] ||= {}
        options['HostConfig']['ExtraHosts'] = ['host.docker.internal:host-gateway']
        options
      end
    end
  end
end
