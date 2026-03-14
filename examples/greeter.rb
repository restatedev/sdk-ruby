# typed: false
# frozen_string_literal: true

#
# Example: Restate Ruby SDK
#
# Demonstrates a stateless Service, a stateful VirtualObject (counter),
# and a Workflow with durable side effects.
#
# Start the server:
#   bundle exec falcon serve --bind http://localhost:9080
#
# Register with Restate:
#   restate deployments register http://localhost:9080
#
# Invoke:
#   curl localhost:8080/Greeter/greet -H 'content-type: application/json' -d '"World"'
#   curl localhost:8080/Counter/add  -H 'content-type: application/json' -d '3'
#   curl localhost:8080/Counter/get  -H 'content-type: application/json' -d 'null'
#   curl localhost:8080/Signup/run   -H 'content-type: application/json' -d '"user@example.com"'

require 'restate'

# ──────────────────────────────────────────────
# 1. Stateless Service
# ──────────────────────────────────────────────

class Greeter < Restate::Service
  handler :greet, input: String, output: String
  def greet(ctx, name)
    # run_sync: durable side effect, returns the value directly
    ctx.run_sync('build-greeting') { "Hello, #{name}!" }
  end

  handler def greetAndRemember(ctx, name) # rubocop:disable Naming/MethodName
    # Typed call: pass class + symbol instead of strings
    count = ctx.object_call(Counter, :add, name, 1).await

    "Hello, #{name}! (greeted #{count['newValue']} times)"
  end
end

# ──────────────────────────────────────────────
# 2. Virtual Object (keyed, stateful)
# ──────────────────────────────────────────────

class Counter < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def get(ctx)
    ctx.get('count') || 0
  end

  handler def add(ctx, addend)
    old_value = ctx.get('count') || 0
    new_value = old_value + addend
    ctx.set('count', new_value)
    { 'oldValue' => old_value, 'newValue' => new_value }
  end

  handler def reset(ctx)
    ctx.clear('count')
    nil
  end
end

# ──────────────────────────────────────────────
# 3. Workflow (runs once per key, durable steps)
# ──────────────────────────────────────────────

class Signup < Restate::Workflow # rubocop:disable Style/OneClassPerFile
  main def run(ctx, email)
    # Step 1: create the user (durable side effect)
    user_id = ctx.run_sync('create-user') do
      "user_#{email.gsub(/[^a-zA-Z0-9]/, '_')}"
    end

    # Step 2: send welcome email
    ctx.run_sync('send-email') do
      puts "Sending welcome email to #{email}"
    end

    # Step 3: store the result
    ctx.set('status', 'completed')

    { 'userId' => user_id, 'email' => email }
  end

  handler def status(ctx)
    ctx.get('status') || 'unknown'
  end
end

# ──────────────────────────────────────────────
# Endpoint — bind all services and serve
# ──────────────────────────────────────────────

ENDPOINT = Restate.endpoint(Greeter, Counter, Signup)
