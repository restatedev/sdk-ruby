# typed: false
# frozen_string_literal: true

require_relative 'services'

e2e_signing_key = ENV.fetch('E2E_REQUEST_SIGNING_ENV', nil)
identity_keys = e2e_signing_key ? [e2e_signing_key] : nil

endpoint = Restate.endpoint(*test_services, identity_keys: identity_keys)

run endpoint.app
