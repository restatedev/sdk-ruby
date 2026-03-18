# typed: true
# frozen_string_literal: true

require 'json'

module Restate
  # JSON serializer/deserializer (default).
  # Converts Ruby objects to JSON byte strings and back.
  module JsonSerde
    extend T::Sig

    module_function

    # Serialize a Ruby object to a JSON byte string. Returns empty bytes for nil.
    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      JSON.generate(obj).b
    end

    # Deserialize a JSON byte string to a Ruby object. Returns nil for nil or empty input.
    sig { params(buf: T.nilable(String)).returns(T.untyped) }
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      JSON.parse(buf, symbolize_names: false)
    end

    # Return the JSON Schema for this serde, or nil if unspecified.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def json_schema
      nil
    end
  end

  # Sentinel value to distinguish "caller didn't pass serde" from an explicit value.
  NOT_SET = Object.new.freeze

  # Pass-through bytes serializer/deserializer.
  # Passes binary data through without transformation.
  module BytesSerde
    extend T::Sig

    module_function

    # Serialize an object by returning its binary encoding. Returns empty bytes for nil.
    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      obj.b
    end

    # Deserialize by returning the raw buffer unchanged.
    sig { params(buf: T.nilable(String)).returns(T.nilable(String)) }
    def deserialize(buf)
      buf
    end

    # Return the JSON Schema for this serde, or nil if unspecified.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def json_schema
      nil
    end
  end

  # Maps Ruby primitive types to JSON Schema snippets for discovery.
  PRIMITIVE_SCHEMAS = {
    String => { 'type' => 'string' },
    Integer => { 'type' => 'integer' },
    Float => { 'type' => 'number' },
    TrueClass => { 'type' => 'boolean' },
    FalseClass => { 'type' => 'boolean' },
    Array => { 'type' => 'array' },
    Hash => { 'type' => 'object' },
    NilClass => { 'type' => 'null' }
  }.freeze

  # Serde resolution utilities: converts a type or serde into a serde object.
  module Serde
    extend T::Sig

    module_function

    # Check if an object quacks like a serde (has serialize + deserialize).
    sig { params(obj: T.untyped).returns(T::Boolean) }
    def serde?(obj)
      obj.respond_to?(:serialize) && obj.respond_to?(:deserialize)
    end

    # Resolve a type or serde into a serde object with serialize/deserialize/json_schema.
    sig { params(type_or_serde: T.untyped).returns(T.untyped) }
    def resolve(type_or_serde)
      return JsonSerde if type_or_serde.nil?
      return type_or_serde if serde?(type_or_serde)
      return TStructSerde.new(type_or_serde) if t_struct?(type_or_serde)
      return DryStructSerde.new(type_or_serde) if dry_struct?(type_or_serde)
      return TypeSerde.new(type_or_serde, PRIMITIVE_SCHEMAS[type_or_serde]) if PRIMITIVE_SCHEMAS.key?(type_or_serde)
      return TypeSerde.new(type_or_serde, type_or_serde.json_schema) if type_or_serde.respond_to?(:json_schema)

      JsonSerde
    end

    # Check if a value is a T::Struct subclass.
    sig { params(val: T.untyped).returns(T::Boolean) }
    def t_struct?(val)
      !!(val.is_a?(Class) && val < T::Struct)
    end

    # Check if a value is a Dry::Struct subclass.
    sig { params(val: T.untyped).returns(T.nilable(T::Boolean)) }
    def dry_struct?(val)
      defined?(::Dry::Struct) && val.is_a?(Class) && val < ::Dry::Struct
    end

    # Generate a JSON Schema from a T::Struct class by introspecting its props.
    sig { params(struct_class: T.class_of(T::Struct)).returns(T::Hash[String, T.untyped]) }
    def t_struct_to_json_schema(struct_class) # rubocop:disable Metrics
      properties = {}
      required = []

      T.unsafe(struct_class).props.each do |name, meta|
        prop_name = (meta[:serialized_form] || name).to_s
        properties[prop_name] = t_type_to_json_schema(meta[:type_object] || meta[:type])
        required << prop_name unless meta[:fully_optional] || meta[:_tnilable]
      end

      schema = { 'type' => 'object', 'properties' => properties }
      schema['required'] = required unless required.empty?
      schema
    end

    # Convert a Sorbet T::Types type object to a JSON Schema hash.
    sig { params(type: T.untyped).returns(T::Hash[String, T.untyped]) }
    def t_type_to_json_schema(type) # rubocop:disable Metrics
      case type
      when T::Types::Simple
        PRIMITIVE_SCHEMAS[type.raw_type] || {}
      when T::Types::Union
        schemas = type.types.map { |t| t_type_to_json_schema(t) }
        schemas.uniq!
        schemas.length == 1 ? schemas.first : { 'anyOf' => schemas }
      when T::Types::TypedArray
        { 'type' => 'array', 'items' => t_type_to_json_schema(type.type) }
      when T::Types::TypedHash
        { 'type' => 'object' }
      when Class
        return t_struct_to_json_schema(type) if type < T::Struct

        PRIMITIVE_SCHEMAS[type] || {}
      else
        {}
      end
    end

    # Generate a JSON Schema from a Dry::Struct class.
    sig { params(struct_class: T.untyped).returns(T::Hash[String, T.untyped]) }
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
    sig { params(type: T.untyped).returns(T::Hash[String, T.untyped]) }
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
    sig { params(type: T.untyped).returns(T::Hash[String, T.untyped]) }
    def nominal_to_json_schema(type)
      prim = type.primitive
      return dry_struct_to_json_schema(prim) if dry_struct?(prim)

      PRIMITIVE_SCHEMAS[prim] || {}
    end
  end

  # Serde wrapper for primitive types and classes with a .json_schema method.
  # Delegates serialize/deserialize to JsonSerde, adds schema.
  class TypeSerde
    extend T::Sig

    sig { returns(T.untyped) }
    attr_reader :type_class

    # Create a TypeSerde for the given type with a precomputed JSON Schema.
    sig { params(type: T.untyped, schema: T.nilable(T::Hash[String, T.untyped])).void }
    def initialize(type, schema)
      @type_class = type
      @schema = schema
    end

    # Serialize a Ruby object to JSON bytes via JsonSerde.
    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      JsonSerde.serialize(obj)
    end

    # Deserialize JSON bytes to a Ruby object via JsonSerde.
    sig { params(buf: T.nilable(String)).returns(T.untyped) }
    def deserialize(buf)
      JsonSerde.deserialize(buf)
    end

    # Return the JSON Schema for this type.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def json_schema
      @schema
    end
  end

  # Serde for Dry::Struct types.
  # Deserializes JSON into struct instances, serializes structs to JSON.
  class DryStructSerde
    extend T::Sig

    sig { returns(T.untyped) }
    attr_reader :struct_class

    # Create a DryStructSerde for the given Dry::Struct class.
    sig { params(struct_class: T.untyped).void }
    def initialize(struct_class)
      @struct_class = struct_class
    end

    # Serialize a Dry::Struct (or hash-like object) to JSON bytes.
    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      hash = obj.respond_to?(:to_h) ? obj.to_h : obj
      JSON.generate(hash).b
    end

    # Deserialize JSON bytes into a Dry::Struct instance.
    sig { params(buf: T.nilable(String)).returns(T.untyped) }
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      hash = JSON.parse(buf, symbolize_names: true)
      @struct_class.new(**hash)
    end

    # Return the JSON Schema derived from the Dry::Struct definition.
    sig { returns(T::Hash[String, T.untyped]) }
    def json_schema
      @json_schema ||= Serde.dry_struct_to_json_schema(@struct_class)
    end
  end

  # Serde for T::Struct types (Sorbet's native typed structs).
  # Uses T::Struct#serialize for output and T::Struct.from_hash for input.
  # Generates JSON Schema from T::Struct props introspection.
  class TStructSerde
    extend T::Sig

    sig { returns(T.class_of(T::Struct)) }
    attr_reader :struct_class

    # Create a TStructSerde for the given T::Struct subclass.
    sig { params(struct_class: T.class_of(T::Struct)).void }
    def initialize(struct_class)
      @struct_class = struct_class
    end

    # Serialize a T::Struct instance to JSON bytes.
    sig { params(obj: T.untyped).returns(String) }
    def serialize(obj)
      return ''.b if obj.nil?

      hash = obj.is_a?(T::Struct) ? obj.serialize : obj
      JSON.generate(hash).b
    end

    # Deserialize JSON bytes into a T::Struct instance.
    sig { params(buf: T.nilable(String)).returns(T.untyped) }
    def deserialize(buf)
      return nil if buf.nil? || buf.empty?

      hash = JSON.parse(buf)
      T.unsafe(@struct_class).from_hash(hash)
    end

    # Return the JSON Schema derived from the T::Struct props.
    sig { returns(T::Hash[String, T.untyped]) }
    def json_schema
      @json_schema ||= Serde.t_struct_to_json_schema(@struct_class)
    end
  end
end
