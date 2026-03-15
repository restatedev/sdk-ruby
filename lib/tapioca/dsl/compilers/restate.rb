# typed: false
# frozen_string_literal: true

return unless defined?(Tapioca::Dsl::Compiler)

module Tapioca
  module Dsl
    module Compilers
      # Generates Sorbet sigs for Restate handler methods.
      #
      # Handlers no longer receive +ctx+ as a parameter — context is accessed
      # via fiber-local +Restate.current_context+ (or typed variants). This
      # compiler generates sigs reflecting the actual handler arity (0 or 1).
      #
      # Usage:
      #   bundle exec tapioca dsl
      class Restate < Compiler
        ConstantType = type_member { { fixed: Module } }

        class << self
          def gather_constants
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
        end

        def decorate
          root.create_path(constant) do |klass|
            constant.handlers.each do |name, handler|
              params = handler.arity == 1 ? [create_param('input', type: 'T.untyped')] : []
              klass.create_method(name, parameters: params, return_type: 'T.untyped')
            end
          end
        end
      end
    end
  end
end
