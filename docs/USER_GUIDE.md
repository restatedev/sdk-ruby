# Restate Ruby SDK — User Guide

Build resilient applications with durable execution in Ruby. The Restate Ruby SDK lets you
write handlers that survive crashes, retries, and infrastructure failures — with the simplicity
of ordinary Ruby code.

---

## Quick Start

### 1. Define a Service

```ruby
# greeter.rb
require 'restate'

class Greeter < Restate::Service
  handler def greet(ctx, name)
    greeting = ctx.run('build-greeting') { "Hello, #{name}!" }.await
    greeting
  end
end

ENDPOINT = Restate.endpoint(Greeter)
```

### 2. Create a Rackup File

```ruby
# config.ru
require_relative 'greeter'
run ENDPOINT.app
```

### 3. Run with Falcon

```bash
bundle exec falcon serve --bind http://localhost:9080
```

### 4. Register with Restate and Invoke

```bash
restate deployments register http://localhost:9080
curl localhost:8080/Greeter/greet -H 'content-type: application/json' -d '"World"'
# → "Hello, World!"
```

---

## Service Types

The SDK provides three service types, each with different durability and concurrency guarantees.

### Service (Stateless)

Stateless handlers that can be invoked by name. Each invocation is independent.

```ruby
class MyService < Restate::Service
  handler def my_handler(ctx, input)
    # input is the deserialized JSON body
    # return value is serialized as the JSON response
    { 'result' => input }
  end
end
```

**Invoke**: `POST /MyService/my_handler`

### VirtualObject (Keyed, Stateful)

Each virtual object instance is identified by a key and has durable K/V state scoped to that key.

```ruby
class Counter < Restate::VirtualObject
  # Exclusive handler — one invocation at a time per key.
  handler def add(ctx, amount)
    current = ctx.get('count') || 0
    ctx.set('count', current + amount)
    current + amount
  end

  # Shared handler — concurrent access allowed (read-only).
  shared def get(ctx)
    ctx.get('count') || 0
  end
end
```

**Invoke**: `POST /Counter/my-counter/add` (key is `my-counter`)

### Workflow (Durable, Run-Once)

A workflow's `main` handler runs exactly once per key. Shared handlers let external callers
query state and send signals.

```ruby
class UserSignup < Restate::Workflow
  main def run(ctx, email)
    user_id = ctx.run('create-account') { create_user(email) }.await
    ctx.set('status', 'waiting_for_approval')

    # Block until approve() is called
    approval = ctx.promise('approval')
    ctx.set('status', 'active')
    { 'user_id' => user_id, 'approval' => approval }
  end

  handler def approve(ctx, reason)
    ctx.resolve_promise('approval', reason)
  end

  handler def status(ctx)
    ctx.get('status') || 'unknown'
  end
end
```

**Invoke**:
```bash
curl localhost:8080/UserSignup/user42/run -d '"user@example.com"'
curl localhost:8080/UserSignup/user42/approve -d '"approved by admin"'
curl localhost:8080/UserSignup/user42/status -d 'null'
```

---

## Context API Reference

The `ctx` object is passed to every handler. All operations that interact with Restate return
durable results — if the handler crashes and retries, completed operations are replayed from the
journal without re-executing.

### Durable Execution (`ctx.run`)

Execute a side effect exactly once. The result is durably recorded — on retry, the block is
skipped and the stored result is returned.

```ruby
result = ctx.run('step-name') { do_something() }.await
```

**With retry policy:**
```ruby
policy = Restate::RunRetryPolicy.new(
  initial_interval: 100,     # ms between retries
  max_attempts: 5,           # max retry count
  interval_factor: 2.0,      # exponential backoff multiplier
  max_interval: 10_000,      # ms cap on retry interval
  max_duration: 60_000       # ms total duration cap
)

result = ctx.run('flaky-call', retry_policy: policy) { call_external_api() }.await
```

**Terminal errors** (non-retryable):
```ruby
ctx.run('validate') do
  raise Restate::TerminalError.new('invalid input', status_code: 400)
end.await
```

### State Operations

Available in `VirtualObject` and `Workflow` handlers.

```ruby
value = ctx.get('key')              # Read state (nil if absent)
ctx.set('key', value)               # Write state
ctx.clear('key')                    # Delete one key
ctx.clear_all                       # Delete all keys
keys = ctx.state_keys               # List all key names
```

Values are JSON-serialized by default. Pass `serde:` for custom serialization:

```ruby
ctx.get('key', serde: Restate::BytesSerde)
ctx.set('key', raw_bytes, serde: Restate::BytesSerde)
```

### Sleep

```ruby
ctx.sleep(5.0).await                # Sleep for 5 seconds (durable timer)
```

The timer survives crashes — if the handler restarts, it resumes waiting for the remaining time.

### Service Communication

#### Synchronous Calls

Call another handler and await the result. The call is durable — if the caller crashes,
Restate delivers the result when the caller retries.

```ruby
# Typed call (resolves serdes from target handler registration)
result = ctx.service_call(MyService, :my_handler, arg).await
result = ctx.object_call(Counter, :add, 'my-key', 5).await
result = ctx.workflow_call(UserSignup, :run, 'user42', email).await

# String-based call (uses JsonSerde)
result = ctx.service_call('MyService', 'my_handler', arg).await
```

**DurableCallFuture methods:**
```ruby
future = ctx.service_call(MyService, :handler, arg)
result = future.await                # Block until result
id = future.invocation_id            # Get invocation ID
future.cancel                        # Cancel the remote invocation
```

#### Fire-and-Forget Sends

Dispatch a call without waiting for the result.

```ruby
handle = ctx.service_send(MyService, :handler, arg)
handle = ctx.object_send(Counter, :add, 'my-key', 5)

# Delayed send (executes after 60 seconds)
handle = ctx.service_send(MyService, :handler, arg, delay: 60.0)
```

**SendHandle methods:**
```ruby
id = handle.invocation_id            # Get invocation ID
handle.cancel                        # Cancel the invocation
```

#### Call Options

All call/send methods accept these keyword arguments:

```ruby
ctx.service_call(
  MyService, :handler, arg,
  idempotency_key: 'unique-key',     # Deduplication key
  headers: { 'x-custom' => 'val' },  # Custom headers
  input_serde: MyCustomSerde,        # Override input serializer
  output_serde: MyCustomSerde        # Override output serializer
)
```

### Fan-Out / Fan-In

Launch multiple calls concurrently, then collect all results.

```ruby
# Fan-out: launch calls
futures = tasks.map { |t| ctx.service_call(Worker, :process, t) }

# Fan-in: await all
results = futures.map(&:await)
```

### Wait Any (Racing Futures)

Wait for the first future to complete out of several.

```ruby
future_a = ctx.service_call(ServiceA, :slow, arg)
future_b = ctx.service_call(ServiceB, :fast, arg)

completed, remaining = ctx.wait_any(future_a, future_b)
winner = completed.first.await
```

### Awakeables (External Callbacks)

Pause a handler until an external system calls back via Restate's API.

```ruby
# In your handler: create an awakeable
awakeable_id, future = ctx.awakeable

# Send the ID to an external system
ctx.run('notify') { send_to_external_system(awakeable_id) }.await

# Block until the external system resolves it
result = future.await
```

The external system resolves the awakeable via Restate's HTTP API:
```bash
curl -X POST http://restate:8080/restate/awakeables/$AWAKEABLE_ID/resolve \
  -H 'content-type: application/json' -d '"callback data"'
```

**From another handler:**
```ruby
ctx.resolve_awakeable(awakeable_id, payload)
ctx.reject_awakeable(awakeable_id, 'reason', code: 500)
```

### Promises (Workflow Only)

Durable promises allow communication between a workflow's main handler and its signal handlers.

```ruby
# In main handler: block until promise is resolved
value = ctx.promise('approval')

# In signal handler: resolve the promise
ctx.resolve_promise('approval', value)

# Non-blocking peek (returns nil if not yet resolved)
value = ctx.peek_promise('approval')

# Reject a promise
ctx.reject_promise('approval', 'denied', code: 400)
```

### Request Metadata

```ruby
request = ctx.request
request.id         # Invocation ID (String)
request.headers    # Request headers (Hash)
request.body       # Raw input bytes (String)

key = ctx.key      # Object/workflow key (String)
```

### Cancel Invocation

```ruby
ctx.cancel_invocation(invocation_id)
```

---

## Handler Registration

### Class-Based DSL (Recommended)

```ruby
class MyService < Restate::Service
  # Inline decorator style
  handler def greet(ctx, name)
    "Hello, #{name}!"
  end

  # With options
  handler :process, input_type: String, output_type: Hash
  def process(ctx, input)
    { 'result' => input.upcase }
  end
end
```

### Handler Options

```ruby
handler :my_handler,
  input_type: String,                  # Generates JSON schema for discovery
  output_type: Hash,                   # Generates JSON schema for discovery
  accept: 'application/json',         # Input content type
  content_type: 'application/json',   # Output content type
  input_serde: Restate::JsonSerde,    # Custom input deserializer
  output_serde: Restate::JsonSerde    # Custom output serializer
```

### Custom Service Name

By default, the service name is the unqualified class name. Override it:

```ruby
class MyLongClassName < Restate::Service
  service_name 'ShortName'
  # Registered as "ShortName" in Restate
end
```

### Handler Arity

Handlers can accept 1 or 2 parameters:

```ruby
handler def no_input(ctx)        # Called with null/empty body
  'ok'
end

handler def with_input(ctx, data)  # data = deserialized JSON body
  data['name']
end
```

---

## Endpoint Configuration

The endpoint binds services and creates the Rack application.

```ruby
# Bind multiple services
endpoint = Restate.endpoint(Greeter, Counter, UserSignup)

# Or bind incrementally
endpoint = Restate.endpoint
endpoint.bind(Greeter)
endpoint.bind(Counter, UserSignup)

# Force protocol mode (auto-detected by default)
endpoint.streaming_protocol           # Force bidirectional streaming
endpoint.request_response_protocol    # Force request/response

# Add identity verification keys
endpoint.identity_key('publickeyv1_...')

# Get the Rack app
run endpoint.app  # In config.ru
```

---

## Serialization

### Built-in Serdes

| Serde | Serialize | Deserialize | Use Case |
|-------|-----------|-------------|----------|
| `JsonSerde` (default) | `JSON.generate` | `JSON.parse` | Structured data |
| `BytesSerde` | Pass-through | Pass-through | Raw bytes |

### Custom Serde

Implement a module with `serialize` and `deserialize`:

```ruby
module MarshalSerde
  def self.serialize(obj)
    Marshal.dump(obj).b
  end

  def self.deserialize(buf)
    Marshal.load(buf)  # rubocop:disable Security/MarshalLoad
  end
end

# Use in handler registration
handler :process, input_serde: MarshalSerde, output_serde: MarshalSerde
```

---

## Error Handling

### TerminalError

Raise `TerminalError` to fail a handler permanently (no retries).

```ruby
raise Restate::TerminalError.new('not found', status_code: 404)
```

Terminal errors propagate through service calls:

```ruby
begin
  ctx.service_call(OtherService, :handler, arg).await
rescue Restate::TerminalError => e
  e.message       # Error message
  e.status_code   # HTTP status code
end
```

### Transient Errors

Any `StandardError` (other than `TerminalError`) triggers a retry of the entire invocation.
Restate automatically retries with exponential backoff.

### Important: Avoid Bare Rescue

**Do not** use bare `rescue => e` in handlers — it catches internal SDK control flow exceptions
(`SuspendedError`, `InternalError`) and breaks the durability protocol.

```ruby
# BAD — catches SuspendedError
begin
  result = ctx.service_call(Other, :handler, arg).await
rescue => e
  handle_error(e)
end

# GOOD — catch only what you mean
begin
  result = ctx.service_call(Other, :handler, arg).await
rescue Restate::TerminalError => e
  handle_error(e)
end
```

---

## Running

### Development

```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080 -n 1
```

### Production

```bash
bundle exec falcon serve --bind http://0.0.0.0:9080
```

### Docker

```dockerfile
FROM ruby:3.3-slim-bookworm
RUN apt-get update && apt-get install -y build-essential curl clang \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle exec rake compile
COPY . .
CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:9080"]
```

### Register with Restate

```bash
# Using Restate CLI
restate deployments register http://localhost:9080

# Using admin API directly
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080"}'

# Force re-register after code changes
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080", "force": true}'
```

---

## Testing

The SDK ships a test harness that starts a real Restate server via Docker, serves your services
on a local Falcon server, and registers them automatically. No external setup is needed — just
Docker.

Opt-in with `require 'restate/testing'`. Add `testcontainers-core` to your Gemfile:

```ruby
gem 'testcontainers-core', require: false
```

### Block-Based (Recommended)

```ruby
require 'restate/testing'

Restate::Testing.start(Greeter, Counter) do |env|
  # env.ingress_url  => "http://localhost:32771"
  # env.admin_url    => "http://localhost:32772"

  uri = URI("#{env.ingress_url}/Greeter/greet")
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request.body = '"World"'
  response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  puts response.body  # => "Hello, World!"
end
# Container and server are automatically cleaned up.
```

### Manual Lifecycle (for RSpec hooks)

```ruby
require 'restate/testing'

RSpec.describe 'my services' do
  before(:all) do
    @harness = Restate::Testing::RestateTestHarness.new(Greeter, Counter)
    @harness.start
  end

  after(:all) do
    @harness&.stop
  end

  it 'greets' do
    uri = URI("#{@harness.ingress_url}/Greeter/greet")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = '"World"'
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    expect(JSON.parse(response.body)).to eq('Hello, World!')
  end
end
```

### Configuration Options

All options are keyword arguments on both `start` and `RestateTestHarness.new`:

| Option | Default | Description |
|--------|---------|-------------|
| `restate_image:` | `"docker.io/restatedev/restate:latest"` | Docker image for Restate server |
| `always_replay:` | `false` | Force replay on every suspension point (useful for catching non-determinism bugs) |
| `disable_retries:` | `false` | Disable Restate retry policy |

```ruby
Restate::Testing.start(MyService, always_replay: true, disable_retries: true) do |env|
  # ...
end
```

### Running Harness Tests

```bash
make test-harness  # Requires Docker
```

---

## URL Patterns

| Service Type | URL Pattern | Example |
|-------------|-------------|---------|
| Service | `/ServiceName/handler` | `/Greeter/greet` |
| VirtualObject | `/ObjectName/key/handler` | `/Counter/my-counter/add` |
| Workflow | `/WorkflowName/key/handler` | `/UserSignup/user42/run` |

---

## Examples

The `examples/` directory contains runnable examples:

| File | Shows |
|------|-------|
| `greeter.rb` | Overview: Service, VirtualObject, Workflow in one file |
| `durable_execution.rb` | `ctx.run`, `RunRetryPolicy`, `TerminalError` |
| `virtual_objects.rb` | State ops, `handler` vs `shared`, `state_keys`, `clear_all` |
| `workflow.rb` | Promises, signals, workflow state |
| `service_communication.rb` | Calls, sends, fan-out/fan-in, `wait_any`, awakeables |

Run any example:
```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080
restate deployments register http://localhost:9080
```

---

## Complete API Quick Reference

### Service Types

```ruby
class MyService < Restate::Service
  handler def method(ctx, arg); end
end

class MyObject < Restate::VirtualObject
  handler def exclusive_method(ctx, arg); end   # One at a time per key
  shared def concurrent_method(ctx); end         # Many readers
end

class MyWorkflow < Restate::Workflow
  main def run(ctx, arg); end                    # Runs once per key
  handler def query(ctx); end                    # Shared handler
end
```

### Context Methods

```ruby
# State (VirtualObject / Workflow)
ctx.get(name) → value | nil
ctx.set(name, value)
ctx.clear(name)
ctx.clear_all
ctx.state_keys → Array[String]

# Durable execution
ctx.run(name, retry_policy: nil) { block } → DurableFuture
ctx.sleep(seconds) → DurableFuture

# Service calls
ctx.service_call(svc, handler, arg) → DurableCallFuture
ctx.object_call(svc, handler, key, arg) → DurableCallFuture
ctx.workflow_call(svc, handler, key, arg) → DurableCallFuture

# Fire-and-forget
ctx.service_send(svc, handler, arg, delay: nil) → SendHandle
ctx.object_send(svc, handler, key, arg, delay: nil) → SendHandle
ctx.workflow_send(svc, handler, key, arg, delay: nil) → SendHandle

# Awakeables
ctx.awakeable → [id, DurableFuture]
ctx.resolve_awakeable(id, payload)
ctx.reject_awakeable(id, message, code: 500)

# Promises (Workflow only)
ctx.promise(name) → value           # Blocks until resolved
ctx.peek_promise(name) → value | nil
ctx.resolve_promise(name, payload)
ctx.reject_promise(name, message, code: 500)

# Futures
ctx.wait_any(*futures) → [completed, remaining]

# Metadata
ctx.request → Request{id, headers, body}
ctx.key → String

# Cancellation
ctx.cancel_invocation(invocation_id)
```

### Future Methods

```ruby
# DurableFuture (from ctx.run, ctx.sleep)
future.await → value
future.completed? → bool

# DurableCallFuture (from ctx.service_call, etc.)
future.await → value
future.completed? → bool
future.invocation_id → String
future.cancel

# SendHandle (from ctx.service_send, etc.)
handle.invocation_id → String
handle.cancel
```
