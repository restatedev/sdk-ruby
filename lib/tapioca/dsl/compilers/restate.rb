# typed: false
# frozen_string_literal: true

return unless defined?(Tapioca::Dsl::Compiler)

module Tapioca
  module Dsl
    module Compilers
      # Generates Sorbet sigs for Restate handler methods.
      #
      # For each handler registered via the +handler+, +shared+, or +main+ DSL,
      # this compiler generates a method sig with the correct context type:
      #
      #   - Service handlers       -> Restate::Context
      #   - VirtualObject handlers -> Restate::ObjectContext
      #   - Workflow handlers      -> Restate::WorkflowContext
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

        def decorate # rubocop:disable Metrics
          root.create_path(constant) do |klass|
            ctx_type = if constant.is_a?(Class) && constant < ::Restate::Workflow
                         '::Restate::WorkflowContext'
                       elsif constant.is_a?(Class) && constant < ::Restate::VirtualObject
                         '::Restate::ObjectContext'
                       else
                         '::Restate::Context'
                       end

            constant.handlers.each do |name, handler|
              params = if handler.arity == 2
                         [
                           create_param('ctx', type: ctx_type),
                           create_param('input', type: 'T.untyped')
                         ]
                       else
                         [create_param('ctx', type: ctx_type)]
                       end

              klass.create_method(name, parameters: params, return_type: 'T.untyped')
            end
          end
        end
      end
    end
  end
end
