# frozen_string_literal: true

require 'restate'

class Greeter < Restate::Service
  handler :greet, input: String, output: String
  # @param name [String]
  # @return [String]
  def greet(name)
    Restate.run_sync('build-greeting') do
      "Hello, #{name}!"
    end
  end
end
