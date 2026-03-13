# typed: true
# frozen_string_literal: true

require 'json'

module Restate
  # JSON serializer/deserializer (default).
  module JsonSerde
    extend T::Sig

    module_function

    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      JSON.generate(obj).encode('UTF-8').b
    end

    sig { params(buf: T.nilable(String)).returns(T.untyped) }
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      JSON.parse(buf, symbolize_names: false)
    end
  end

  # Pass-through bytes serializer/deserializer.
  module BytesSerde
    extend T::Sig

    module_function

    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      obj.b
    end

    sig { params(buf: T.untyped).returns(T.untyped) }
    def deserialize(buf)
      buf
    end
  end
end
