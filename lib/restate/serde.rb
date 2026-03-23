# typed: true
# frozen_string_literal: true

require 'json'

module Restate
  EMPTY_BYTES = ''.b.freeze
  private_constant :EMPTY_BYTES

  # JSON serializer/deserializer (default).
  # Converts Ruby objects to JSON byte strings and back.
  module JsonSerde
    module_function

    # Serialize a Ruby object to a JSON byte string. Returns empty bytes for nil.
    def serialize(obj)
      return EMPTY_BYTES if obj.nil?

      JSON.generate(obj).b
    end

    # Deserialize a JSON byte string to a Ruby object. Returns nil for nil or empty input.
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      JSON.parse(buf, symbolize_names: false)
    end

    # Return the JSON Schema for this serde, or nil if unspecified.
    def json_schema
      nil
    end
  end

  # Sentinel value to distinguish "caller didn't pass serde" from an explicit value.
  NOT_SET = Object.new.freeze

  # Pass-through bytes serializer/deserializer.
  # Passes binary data through without transformation.
  module BytesSerde
    module_function

    # Serialize an object by returning its binary encoding. Returns empty bytes for nil.
    def serialize(obj)
      return EMPTY_BYTES if obj.nil?

      obj.b
    end

    # Deserialize by returning the raw buffer unchanged.
    def deserialize(buf)
      buf
    end

    # Return the JSON Schema for this serde, or nil if unspecified.
    def json_schema
      nil
    end
  end

  # Maps Ruby primitive types to JSON Schema snippets for discovery.
  PRIMITIVE_SCHEMAS = {
    String => { 'type' => 'string' }.freeze,
    Integer => { 'type' => 'integer' }.freeze,
    Float => { 'type' => 'number' }.freeze,
    TrueClass => { 'type' => 'boolean' }.freeze,
    FalseClass => { 'type' => 'boolean' }.freeze,
    Array => { 'type' => 'array' }.freeze,
    Hash => { 'type' => 'object' }.freeze,
    NilClass => { 'type' => 'null' }.freeze
  }.freeze

  # Serde resolution utilities: converts a type or serde into a serde object.
  module Serde
    module_function

    # Check if an object quacks like a serde (has serialize + deserialize).
    def serde?(obj)
      obj.respond_to?(:serialize) && obj.respond_to?(:deserialize)
    end

    # Resolve a type or serde into a serde object with serialize/deserialize/json_schema.
    def resolve(type_or_serde)
      return JsonSerde if type_or_serde.nil?
      return type_or_serde if serde?(type_or_serde)
      return DryStructSerde.new(type_or_serde) if dry_struct?(type_or_serde)
      return TypeSerde.new(type_or_serde, PRIMITIVE_SCHEMAS[type_or_serde]) if PRIMITIVE_SCHEMAS.key?(type_or_serde)
      return TypeSerde.new(type_or_serde, type_or_serde.json_schema) if type_or_serde.respond_to?(:json_schema)

      JsonSerde
    end

    # Check if a value is a Dry::Struct subclass.
    def dry_struct?(val)
      defined?(::Dry::Struct) && val.is_a?(Class) && val < ::Dry::Struct
    end

    # Generate a JSON Schema from a Dry::Struct class.
    def dry_struct_to_json_schema(struct_class)
      properties = {}
      required = []

      struct_class.schema.each do |key|
        name = key.name.to_s
        properties[name] = dry_type_to_json_schema(key.type)
        required << name if key.required?
      end

      schema = { 'type' => 'object', 'properties' => properties }
      schema['required'] = required unless required.empty?
      schema
    end

    # Convert a dry-types type to a JSON Schema hash.
    def dry_type_to_json_schema(type) # rubocop:disable Metrics
      type_class = type.class.name || ''

      # Constrained -> unwrap
      return dry_type_to_json_schema(type.type) if type_class.include?('Constrained') && type.respond_to?(:type)

      # Sum -> anyOf
      if type.respond_to?(:left) && type.respond_to?(:right)
        left = dry_type_to_json_schema(type.left)
        right = dry_type_to_json_schema(type.right)
        return left if left == right

        return { 'anyOf' => [left, right] }
      end

      # Array with member type
      return { 'type' => 'array', 'items' => dry_type_to_json_schema(type.member) } if type.respond_to?(:member)

      # Nominal type with primitive
      return nominal_to_json_schema(type) if type.respond_to?(:primitive)

      {}
    end

    # Convert a nominal dry-type (with .primitive) to JSON Schema.
    def nominal_to_json_schema(type)
      prim = type.primitive
      return dry_struct_to_json_schema(prim) if dry_struct?(prim)

      PRIMITIVE_SCHEMAS[prim] || {}
    end
  end

  # Serde wrapper for primitive types and classes with a .json_schema method.
  # Delegates serialize/deserialize to JsonSerde, adds schema.
  class TypeSerde
    attr_reader :type_class

    # Create a TypeSerde for the given type with a precomputed JSON Schema.
    def initialize(type, schema)
      @type_class = type
      @schema = schema
    end

    # Serialize a Ruby object to JSON bytes via JsonSerde.
    def serialize(obj)
      JsonSerde.serialize(obj)
    end

    # Deserialize JSON bytes to a Ruby object via JsonSerde.
    def deserialize(buf)
      JsonSerde.deserialize(buf)
    end

    # Return the JSON Schema for this type.
    def json_schema
      @schema
    end
  end

  # Serde for Dry::Struct types.
  # Deserializes JSON into struct instances, serializes structs to JSON.
  class DryStructSerde
    attr_reader :struct_class

    # Create a DryStructSerde for the given Dry::Struct class.
    def initialize(struct_class)
      @struct_class = struct_class
    end

    # Serialize a Dry::Struct (or hash-like object) to JSON bytes.
    def serialize(obj)
      return EMPTY_BYTES if obj.nil?

      hash = obj.respond_to?(:to_h) ? obj.to_h : obj
      JSON.generate(hash).b
    end

    # Deserialize JSON bytes into a Dry::Struct instance.
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      hash = JSON.parse(buf, symbolize_names: true)
      @struct_class.new(**hash)
    end

    # Return the JSON Schema derived from the Dry::Struct definition.
    def json_schema
      @json_schema ||= Serde.dry_struct_to_json_schema(@struct_class)
    end
  end
end
