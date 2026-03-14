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

# Restate Ruby SDK — build resilient applications with durable execution.
module Restate
  extend T::Sig

  module_function

  # Create a new instance-based stateless Service.
  #
  # @param name [String] the service name
  # @return [Service]
  sig { params(name: String, opts: T.untyped).returns(Service) }
  def service(name, **opts)
    Service.new(name, **opts)
  end

  # Create a new instance-based VirtualObject.
  #
  # @param name [String] the virtual object name
  # @return [VirtualObject]
  sig { params(name: String, opts: T.untyped).returns(VirtualObject) }
  def virtual_object(name, **opts)
    VirtualObject.new(name, **opts)
  end

  # Create a new instance-based Workflow.
  #
  # @param name [String] the workflow name
  # @return [Workflow]
  sig { params(name: String, opts: T.untyped).returns(Workflow) }
  def workflow(name, **opts)
    Workflow.new(name, **opts)
  end

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
end
