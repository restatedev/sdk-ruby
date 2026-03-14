# typed: true

module Async
  class Queue
    sig { void }
    def initialize; end

    sig { params(item: T.untyped).void }
    def enqueue(item); end

    sig { returns(T.untyped) }
    def dequeue; end
  end

  module HTTP
    class Endpoint
      sig { params(url: String, options: T.untyped).returns(T.untyped) }
      def self.parse(url, **options); end
    end
  end
end

module Falcon
  class Server
    sig { params(middleware: T.untyped, endpoint: T.untyped).void }
    def initialize(middleware, endpoint); end

    sig { params(app: T.untyped, options: T.untyped).returns(T.untyped) }
    def self.middleware(app, **options); end

    sig { void }
    def run; end
  end
end

module Testcontainers
  class DockerContainer
    sig { params(image: String).void }
    def initialize(image); end
  end
end

module Kernel
  sig { params(block: T.proc.void).returns(T.untyped) }
  def Async(&block); end
end
