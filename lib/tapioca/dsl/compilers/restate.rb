# typed: false
# frozen_string_literal: true

return unless defined?(Tapioca::Dsl::Compiler)

require 'restate'

module Tapioca
  module Dsl
    module Compilers
      # Generates Sorbet sigs for Restate handler methods.
      #
      # Handlers take 0 or 1 parameters (the input). Context is implicit
      # via +Restate.*+ module methods.
      #
      # Usage:
      #   bundle exec tapioca dsl
      class Restate < Compiler
        ConstantType = type_member { { fixed: Module } }

        class << self
          def gather_constants
            # Load service files so they're visible to all_classes.
            # In non-Rails apps, Tapioca doesn't auto-load application code.
            load_service_files

            all_classes.select do |klass|
              klass.is_a?(Class) && (
                klass < ::Restate::Service ||
                klass < ::Restate::VirtualObject ||
                klass < ::Restate::Workflow
              )
            rescue TypeError
              false
            end
          end

          private

          def load_service_files # rubocop:disable Metrics/MethodLength
            root = Bundler.root.to_s
            patterns = [
              "#{root}/*.rb",
              "#{root}/app/**/*.rb",
              "#{root}/services/**/*.rb",
              "#{root}/examples/**/*.rb"
            ]
            Dir.glob(patterns).each do |file|
              next if file.end_with?('config.ru', 'Rakefile')

              require file
            rescue LoadError, StandardError
              nil # skip files that can't be loaded
            end
          end
        end

        def decorate # rubocop:disable Metrics/MethodLength
          root.create_path(constant) do |klass|
            constant.handlers.each do |name, handler|
              params = []
              if handler.arity == 1
                input_type = resolve_input_type(handler)
                params << create_param('input', type: input_type)
              end
              output_type = resolve_output_type(handler)
              klass.create_method(name, parameters: params, return_type: output_type)
            end
          end
        end

        private

        # Maps (service kind, handler kind) to the correct context module.
        def resolve_context_type(klass, handler)
          if klass < ::Restate::Workflow
            handler.kind == 'workflow' ? 'Restate::WorkflowContext' : 'Restate::WorkflowSharedContext'
          elsif klass < ::Restate::VirtualObject
            handler.kind == 'shared' ? 'Restate::ObjectSharedContext' : 'Restate::ObjectContext'
          else
            'Restate::Context'
          end
        end

        # Resolves the Sorbet type string for the handler's input serde.
        def resolve_input_type(handler)
          type_class = handler.handler_io&.input_serde
          sorbet_type_name(type_class) || 'T.untyped'
        end

        # Resolves the Sorbet type string for the handler's output serde.
        def resolve_output_type(handler)
          type_class = handler.handler_io&.output_serde
          sorbet_type_name(type_class) || 'T.untyped'
        end

        # Returns a Sorbet type string if the serde wraps a known type, nil otherwise.
        def sorbet_type_name(serde)
          return nil if serde.nil?

          # TStructSerde exposes .struct_class (T::Struct subclasses are visible to Sorbet)
          return serde.struct_class.name if serde.is_a?(::Restate::TStructSerde)

          # TypeSerde wraps a primitive type in .type_class
          if serde.respond_to?(:type_class)
            name = serde.type_class.name
            return name if %w[String Integer Float].include?(name)
          end

          nil
        end
      end
    end
  end
end
