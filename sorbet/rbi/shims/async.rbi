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
end

module Kernel
  sig { params(block: T.proc.void).returns(T.untyped) }
  def Async(&block); end
end
