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

  # Sentinel value to distinguish "caller didn't pass serde" from an explicit value.
  NOT_SET = Object.new.freeze

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

  # Maps Ruby primitive types to JSON Schema snippets for discovery.
  PRIMITIVE_SCHEMAS = T.let({
    String => { 'type' => 'string' },
    Integer => { 'type' => 'integer' },
    Float => { 'type' => 'number' },
    TrueClass => { 'type' => 'boolean' },
    FalseClass => { 'type' => 'boolean' },
    Array => { 'type' => 'array' },
    Hash => { 'type' => 'object' },
    NilClass => { 'type' => 'null' }
  }.freeze, T::Hash[T::Class[T.anything], T::Hash[String, String]])

  extend T::Sig

  # Compute a JSON Schema hash for a given type.
  # Returns nil if the type is nil or unrecognized.
  sig { params(type: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.compute_json_schema(type)
    return nil if type.nil?

    if type.respond_to?(:json_schema)
      type.json_schema
    else
      PRIMITIVE_SCHEMAS[type]
    end
  end
end
