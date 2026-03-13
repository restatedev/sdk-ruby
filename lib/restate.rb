# typed: true
# frozen_string_literal: true

require 'sorbet-runtime'
require_relative 'restate/version'
require_relative 'restate/errors'
require_relative 'restate/serde'
require_relative 'restate/vm'
require_relative 'restate/context'
require_relative 'restate/handler'
require_relative 'restate/service'
require_relative 'restate/virtual_object'
require_relative 'restate/workflow'
require_relative 'restate/server_context'
require_relative 'restate/discovery'
require_relative 'restate/endpoint'

module Restate
  extend T::Sig

  module_function

  # Create a new Service.
  sig { params(name: String, opts: T.untyped).returns(Service) }
  def service(name, **opts)
    Service.new(name, **opts)
  end

  # Create a new VirtualObject.
  sig { params(name: String, opts: T.untyped).returns(VirtualObject) }
  def virtual_object(name, **opts)
    VirtualObject.new(name, **opts)
  end

  # Create a new Workflow.
  sig { params(name: String, opts: T.untyped).returns(Workflow) }
  def workflow(name, **opts)
    Workflow.new(name, **opts)
  end

  # Create an endpoint binding services, and return the Rack app.
  sig do
    params(
      services: T.any(Service, VirtualObject, Workflow),
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
