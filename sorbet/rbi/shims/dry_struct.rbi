# typed: true

module Dry
  class Struct
    sig { params(args: T.untyped).void }
    def initialize(**args); end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h; end

    sig { returns(T.untyped) }
    def self.schema; end

    sig { returns(T::Array[Symbol]) }
    def self.attribute_names; end
  end
end
