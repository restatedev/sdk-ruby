# typed: true

# Minimal shims for Async/Falcon/Testcontainers — enough for Sorbet to check our code.

module Kernel
  def Async(&block); end
end

module Async
  class Queue
    def initialize; end
    def enqueue(item); end
    def dequeue; end
  end

  class HTTP
    class Body
      class Hijack
        def initialize(&block); end
      end
    end
  end
end

module Falcon
  class Server
    def initialize(app, endpoint, **opts); end
    def start; end
    def stop; end
  end

  module Endpoint
    def self.parse(url); end
  end
end

module Testcontainers
  class DockerContainer
    def initialize(image, **opts); end
    def start; end
    def stop; end
    def remove; end
    def mapped_port(port); end
    def host; end
    def logs; end
    def wait_for_logs(matcher, timeout:); end
    def with_exposed_ports(*ports); end
    def with_env(env); end
    def wait_for_http(path:, port:, timeout:); end

    private
    def _container_create_options; end
  end
end
