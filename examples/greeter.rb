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
#   curl localhost:8080/Counter/add  -H 'content-type: application/json' -d '3' -H 'idempotency-key: my-key'
#   curl localhost:8080/Counter/get  -H 'content-type: application/json' -d 'null'
#   curl localhost:8080/Signup/run   -H 'content-type: application/json' -d '"user@example.com"' -H 'idempotency-key: signup-1'

require "restate"

# ──────────────────────────────────────────────
# 1. Stateless Service
# ──────────────────────────────────────────────

greeter = Restate.service("Greeter")

greeter.handler("greet") do |ctx, name|
  greeting = ctx.run("build-greeting") { "Hello, #{name}!" }
  greeting
end

greeter.handler("greetAndRemember") do |ctx, name|
  # Call the Counter virtual object to track how many times we greeted
  count = ctx.object_call("Counter", "add", name, 1)

  "Hello, #{name}! (greeted #{count['newValue']} times)"
end

# ──────────────────────────────────────────────
# 2. Virtual Object (keyed, stateful)
# ──────────────────────────────────────────────

counter = Restate.virtual_object("Counter")

counter.handler("get") do |ctx|
  ctx.get("count") || 0
end

counter.handler("add") do |ctx, addend|
  old_value = ctx.get("count") || 0
  new_value = old_value + addend
  ctx.set("count", new_value)
  { "oldValue" => old_value, "newValue" => new_value }
end

counter.handler("reset") do |ctx|
  ctx.clear("count")
  nil
end

# ──────────────────────────────────────────────
# 3. Workflow (runs once per key, durable steps)
# ──────────────────────────────────────────────

signup = Restate.workflow("Signup")

signup.main("run") do |ctx, email|
  # Step 1: create the user (durable side effect)
  user_id = ctx.run("create-user") do
    # Simulate creating a user in a database
    "user_#{email.gsub(/[^a-zA-Z0-9]/, '_')}"
  end

  # Step 2: send welcome email
  ctx.run("send-email") do
    # Simulate sending an email
    puts "Sending welcome email to #{email}"
  end

  # Step 3: store the result
  ctx.set("status", "completed")

  { "userId" => user_id, "email" => email }
end

signup.handler("status") do |ctx|
  ctx.get("status") || "unknown"
end

# ──────────────────────────────────────────────
# Endpoint — bind all services and serve
# ──────────────────────────────────────────────

ENDPOINT = Restate.endpoint(greeter, counter, signup)
