# frozen_string_literal: true

# Steepfile — configuration for the Steep type checker.
# Run: bundle exec steep check

target :lib do
  signature 'sig'

  check 'lib/restate/config.rb'
  check 'lib/restate/errors.rb'
  check 'lib/restate/durable_future.rb'
  check 'lib/restate/endpoint.rb'
  check 'lib/restate/service_proxy.rb'
  check 'lib/restate/client.rb'

  # Files with heavy metaprogramming — skip for now
  # check "lib/restate.rb"               # module_function pattern
  # check "lib/restate/service.rb"       # extend ServiceDSL
  # check "lib/restate/virtual_object.rb"
  # check "lib/restate/workflow.rb"
  # check "lib/restate/service_dsl.rb"   # define_method
  # check "lib/restate/server_context.rb"
  # check "lib/restate/server.rb"
  # check "lib/restate/vm.rb"
  # check "lib/restate/context.rb"
  # check "lib/restate/discovery.rb"
  # check "lib/restate/serde.rb"
  # check "lib/restate/handler.rb"
  # check "lib/restate/testing.rb"

  library 'json'
  library 'net-http'
  library 'uri'

  # method_missing proxies can't be fully typed
  configure_code_diagnostics do |hash|
    hash[Steep::Diagnostic::Ruby::MethodArityMismatch] = :information
  end
end
