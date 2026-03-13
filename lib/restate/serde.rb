# frozen_string_literal: true

require "json"

module Restate
  # JSON serializer/deserializer (default).
  module JsonSerde
    module_function

    def serialize(obj)
      return "".b if obj.nil?

      JSON.generate(obj).encode("UTF-8").b
    end

    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      JSON.parse(buf, symbolize_names: false)
    end
  end

  # Pass-through bytes serializer/deserializer.
  module BytesSerde
    module_function

    def serialize(obj)
      return "".b if obj.nil?

      obj.b
    end

    def deserialize(buf)
      buf
    end
  end
end
