# typed: true
# frozen_string_literal: true

require 'restate'

class GreetingRequest < T::Struct
  const :name, String
end

class GreetingResponse < T::Struct # rubocop:disable Style/OneClassPerFile
  const :message, String
end

class Greeter < Restate::Service # rubocop:disable Style/OneClassPerFile
  handler :greet, input: GreetingRequest, output: GreetingResponse
  def greet(request)
    ctx = Restate.current_context

    message = ctx.run_sync('build-greeting') do
      "Hello, #{request.name}!"
    end

    GreetingResponse.new(message: message)
  end
end
