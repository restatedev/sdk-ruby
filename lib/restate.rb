# typed: true
# frozen_string_literal: true

require 'sorbet-runtime'
require_relative 'restate/version'
require_relative 'restate/errors'
require_relative 'restate/serde'
require_relative 'restate/vm'
require_relative 'restate/context'
require_relative 'restate/handler'
require_relative 'restate/service_dsl'
require_relative 'restate/service'
require_relative 'restate/virtual_object'
require_relative 'restate/workflow'
require_relative 'restate/server_context'
require_relative 'restate/durable_future'
require_relative 'restate/discovery'
require_relative 'restate/endpoint'
require_relative 'restate/service_proxy'
require_relative 'restate/client'

# Restate Ruby SDK — build resilient applications with durable execution.
module Restate
  extend T::Sig

  module_function

  # Create an endpoint, optionally binding services.
  # Returns an Endpoint that can be further configured before calling +.app+.
  #
  # @param services [Array<Class>] service classes or instances to bind
  # @return [Endpoint]
  sig do
    params(
      services: T.untyped,
      protocol: T.nilable(String),
      identity_keys: T.nilable(T::Array[String])
    ).returns(Endpoint)
  end
  def endpoint(*services, protocol: nil, identity_keys: nil)
    ep = Endpoint.new
    ep.streaming_protocol if protocol == 'bidi'
    ep.request_response_protocol if protocol == 'request_response'
    services.each { |s| ep.bind(s) }
    identity_keys&.each { |k| ep.identity_key(k) }
    ep
  end

  # ── Fiber-local context accessors ──
  #
  # The SDK passes the context as the first argument to every handler.
  # It is also stored in fiber-local storage (Thread.current[], which is
  # fiber-scoped in Ruby). These methods retrieve it with the appropriate
  # type for IDE completion.
  #
  # Use these from nested helper methods that don't have +ctx+ in scope.

  # Returns the current context for a Service handler.
  # Raises if called outside a Restate handler.
  #
  # @return [Context]
  sig { returns(Context) }
  def current_context
    fetch_context!
  end

  # Returns the current context for a VirtualObject exclusive handler.
  # Raises if not inside a VirtualObject exclusive handler.
  #
  # @return [ObjectContext]
  sig { returns(ObjectContext) }
  def current_object_context
    fetch_context!(service_kind: 'object', handler_kind: 'exclusive')
  end

  # Returns the current context for a VirtualObject shared handler.
  # Read-only state: +get+ and +state_keys+ only, no +set+/+clear+.
  # Raises if not inside a VirtualObject shared handler.
  #
  # @return [ObjectSharedContext]
  sig { returns(ObjectSharedContext) }
  def current_shared_context
    fetch_context!(service_kind: 'object', handler_kind: 'shared')
  end

  # Returns the current context for a Workflow main handler.
  # Raises if not inside a Workflow main handler.
  #
  # @return [WorkflowContext]
  sig { returns(WorkflowContext) }
  def current_workflow_context
    fetch_context!(service_kind: 'workflow', handler_kind: 'workflow')
  end

  # Returns the current context for a Workflow shared handler.
  # Read-only state: +get+ and +state_keys+ only, no +set+/+clear+.
  # Raises if not inside a Workflow shared handler.
  #
  # @return [WorkflowSharedContext]
  sig { returns(WorkflowSharedContext) }
  def current_shared_workflow_context
    fetch_context!(service_kind: 'workflow', handler_kind: 'shared')
  end

  # @!visibility private
  sig do
    params(service_kind: T.nilable(String), handler_kind: T.nilable(String)).returns(ServerContext)
  end
  def fetch_context!(service_kind: nil, handler_kind: nil) # rubocop:disable Metrics
    ctx = Thread.current[:restate_context]
    unless ctx
      Kernel.raise 'Not inside a Restate handler. ' \
                   'Context accessors can only be called during handler execution.'
    end

    if service_kind
      actual_service = Thread.current[:restate_service_kind]
      unless actual_service == service_kind
        Kernel.raise "Expected a #{service_kind} handler, but current handler is #{actual_service || 'unknown'}."
      end
    end

    if handler_kind
      actual_handler = Thread.current[:restate_handler_kind]
      unless actual_handler == handler_kind
        Kernel.raise "Expected a #{handler_kind} handler, but current handler kind is #{actual_handler || 'unknown'}."
      end
    end

    T.cast(ctx, ServerContext)
  end
end
