# typed: true
# frozen_string_literal: true

#
# Example: Restate Ruby SDK — Hello World
#
# The simplest possible service: a stateless greeter.
#
# Start the server:
#   cd examples && bundle exec falcon serve --bind http://localhost:9080
#
# Register with Restate:
#   restate deployments register http://localhost:9080
#
# Invoke:
#   curl localhost:8080/Greeter/greet -H 'content-type: application/json' -d '"World"'

require 'restate'

class Greeter < Restate::Service
  handler :greet, input: String, output: String
  # @param name [String]
  # @return [String]
  def greet(name)
    # run_sync: durable side effect, returns the value directly
    Restate.run_sync('build-greeting') { "Hello, #{name}!" }
  end
end
