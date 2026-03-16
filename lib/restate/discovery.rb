# typed: true
# frozen_string_literal: true

require 'json'

module Restate
  module Discovery # rubocop:disable Metrics/ModuleLength
    extend T::Sig

    PROTOCOL_MODES = T.let({
      'bidi' => 'BIDI_STREAM',
      'request_response' => 'REQUEST_RESPONSE'
    }.freeze, T::Hash[String, String])

    SERVICE_TYPES = T.let({
      'service' => 'SERVICE',
      'object' => 'VIRTUAL_OBJECT',
      'workflow' => 'WORKFLOW'
    }.freeze, T::Hash[String, String])

    HANDLER_TYPES = T.let({
      'exclusive' => 'EXCLUSIVE',
      'shared' => 'SHARED',
      'workflow' => 'WORKFLOW'
    }.freeze, T::Hash[String, String])

    module_function

    # Generate the discovery JSON for the given endpoint.
    sig { params(endpoint: Endpoint, _version: Integer, discovered_as: String).returns(String) }
    def compute_discovery_json(endpoint, _version, discovered_as)
      ep = compute_discovery(endpoint, discovered_as)
      JSON.generate(ep, allow_nan: false)
    end

    # Build the discovery hash for the endpoint.
    sig { params(endpoint: Endpoint, discovered_as: String).returns(T::Hash[Symbol, T.untyped]) }
    def compute_discovery(endpoint, discovered_as)
      services = endpoint.services.values.map do |service|
        build_service(service)
      end

      protocol_mode = PROTOCOL_MODES.fetch(endpoint.protocol || discovered_as)

      compact(
        protocolMode: protocol_mode,
        minProtocolVersion: 5,
        maxProtocolVersion: 5,
        services: services
      )
    end

    sig { params(service: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def build_service(service) # rubocop:disable Metrics/AbcSize
      service_type = SERVICE_TYPES.fetch(service.service_tag.kind)

      handlers = service.handlers.values.map do |handler|
        build_handler(handler)
      end

      svc_name = service.service_name

      result = compact(
        name: svc_name,
        ty: service_type,
        handlers: handlers,
        documentation: service.service_tag.description,
        metadata: service.service_tag.metadata,
        enableLazyState: service.lazy_state?,
        inactivityTimeout: seconds_to_ms(service.svc_inactivity_timeout),
        abortTimeout: seconds_to_ms(service.svc_abort_timeout),
        journalRetention: seconds_to_ms(service.svc_journal_retention),
        idempotencyRetention: seconds_to_ms(service.svc_idempotency_retention),
        ingressPrivate: service.svc_ingress_private
      )

      policy = service.svc_invocation_retry_policy
      merge_retry_policy!(result, policy) if policy

      result
    end

    sig { params(handler: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def build_handler(handler) # rubocop:disable Metrics/AbcSize
      ty = handler.kind ? HANDLER_TYPES.fetch(handler.kind) : nil

      input_payload = {
        required: false,
        contentType: handler.handler_io.accept,
        jsonSchema: handler.handler_io.input_serde.json_schema
      }

      output_payload = {
        setContentTypeIfEmpty: false,
        contentType: handler.handler_io.content_type,
        jsonSchema: handler.handler_io.output_serde.json_schema
      }

      result = compact(
        name: handler.name,
        ty: ty,
        input: compact(**input_payload),
        output: compact(**output_payload),
        enableLazyState: handler.enable_lazy_state,
        documentation: handler.description,
        metadata: handler.metadata,
        inactivityTimeout: seconds_to_ms(handler.inactivity_timeout),
        abortTimeout: seconds_to_ms(handler.abort_timeout),
        journalRetention: seconds_to_ms(handler.journal_retention),
        idempotencyRetention: seconds_to_ms(handler.idempotency_retention),
        workflowCompletionRetention: seconds_to_ms(handler.workflow_completion_retention),
        ingressPrivate: handler.ingress_private
      )

      merge_retry_policy!(result, handler.invocation_retry_policy) if handler.invocation_retry_policy

      result
    end

    # Convert seconds to milliseconds (integer). Returns nil if input is nil.
    sig { params(seconds: T.nilable(Numeric)).returns(T.nilable(Integer)) }
    def seconds_to_ms(seconds)
      return nil if seconds.nil?

      (seconds * 1000).to_i
    end

    # Merge retry policy fields (flattened) into the target hash.
    sig { params(target: T::Hash[Symbol, T.untyped], policy: T.nilable(T::Hash[Symbol, T.untyped])).void }
    def merge_retry_policy!(target, policy) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
      return if policy.nil? || policy.empty?

      target[:retryPolicyInitialInterval] = seconds_to_ms(policy[:initial_interval]) if policy[:initial_interval]
      target[:retryPolicyMaxInterval] = seconds_to_ms(policy[:max_interval]) if policy[:max_interval]
      target[:retryPolicyMaxAttempts] = policy[:max_attempts] if policy[:max_attempts]
      target[:retryPolicyExponentiationFactor] = policy[:exponentiation_factor] if policy[:exponentiation_factor]
      target[:retryPolicyOnMaxAttempts] = policy[:on_max_attempts].to_s.upcase if policy[:on_max_attempts]
    end

    # Remove nil values from a hash (non-recursive for top level, recursive for nested).
    sig { params(kwargs: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def compact(**kwargs)
      kwargs.each_with_object({}) do |(k, v), result|
        next if v.nil?

        result[k] = v.is_a?(Hash) ? compact(**v) : v
      end
    end
  end
end
