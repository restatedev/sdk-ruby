# Restate Ruby SDK Project

This is a Restate service written in Ruby using the [Restate Ruby SDK](https://github.com/restatedev/sdk-ruby).

## What is Restate?

Restate is a system for building resilient applications using distributed durable async/await.
Handlers survive crashes, retries, and infrastructure failures — with the simplicity of ordinary Ruby code.

## Project structure

- `config.ru` — Rack entry point, binds services to a Restate endpoint
- `greeter.rb` — Example service (add your own service files alongside it)
- `Gemfile` — Dependencies
- `Makefile` — `make verify` runs tapioca + lint + typecheck

## Running

```bash
bundle exec falcon serve --bind http://localhost:9080   # Start the service
restate deployments register http://localhost:9080       # Register with Restate
```

## Key concepts

### Service types

- `Restate::Service` — Stateless handlers, invoked by name
- `Restate::VirtualObject` — Keyed, stateful handlers (one invocation at a time per key)
- `Restate::Workflow` — Durable run-once workflows with promises for signaling

### Context

Every handler receives a context object as its first argument:

```ruby
handler def greet(ctx, name)               # ctx is always the first parameter
  ctx.run_sync('step') { ... }
end
```

For nested helper methods, use the fiber-local accessors:
```ruby
Restate.current_context              # Service handlers
Restate.current_object_context       # VirtualObject handlers
Restate.current_workflow_context     # Workflow handlers
```

### Durable execution

```ruby
# Side effect — runs exactly once, result is journaled
result = ctx.run_sync('step-name') { do_something() }

# Async variant — returns a future
future = ctx.run('step-name') { do_something() }
result = future.await
```

### State (VirtualObject / Workflow only)

```ruby
ctx.get('key')                # Read (nil if absent)
ctx.set('key', value)         # Write
ctx.clear('key')              # Delete
ctx.clear_all                 # Delete all
ctx.state_keys                # List keys
```

### Service communication

```ruby
# Synchronous call (durable)
result = ctx.service_call(MyService, :handler, arg).await
result = ctx.object_call(MyObject, :handler, 'key', arg).await

# Fire-and-forget
ctx.service_send(MyService, :handler, arg)
ctx.object_send(MyObject, :handler, 'key', arg, delay: 60.0)
```

### Typed handlers with T::Struct

Use Sorbet's `T::Struct` for typed input/output with automatic JSON Schema generation:

```ruby
class MyRequest < T::Struct
  const :name, String
  const :age, T.nilable(Integer)
end

class MyService < Restate::Service
  handler :process, input: MyRequest, output: String
  def process(ctx, request)
    "Hello, #{request.name}!"
  end
end
```

Supported types: `String`, `Integer`, `Float`, `T::Boolean`, `T.nilable(...)`, `T::Array[...]`, `T::Hash[...]`, nested `T::Struct`.

### Sleep (durable timer)

```ruby
ctx.sleep(5.0).await          # Survives crashes
```

### Awakeables (external callbacks)

```ruby
awakeable_id, future = ctx.awakeable
ctx.run_sync('notify') { send_to_external(awakeable_id) }
result = future.await
```

### Promises (Workflow only)

```ruby
value = ctx.promise('approval')                    # Block until resolved
ctx.resolve_promise('approval', value)             # From signal handler
```

### Error handling

```ruby
# Terminal error — no retries
raise Restate::TerminalError.new('not found', status_code: 404)

# Any other StandardError triggers a retry
# IMPORTANT: never use bare `rescue => e` — it catches internal SDK exceptions
```

### Endpoint configuration

```ruby
endpoint = Restate.endpoint(ServiceA, ServiceB)
run endpoint.app   # in config.ru
```

## Verification

Always run `make verify` after changes. This runs tapioca (type generation), rubocop (lint),
and sorbet (typecheck).

## Code style

- Use `T::Struct` for typed handler input/output
- Every handler receives `ctx` as its first argument
- Use `Restate.current_context` (or variants) only in nested helper methods
- Use `run_sync` for sequential side effects, `run` + `.await` for fan-out
- Catch `Restate::TerminalError` specifically, never bare `rescue => e`
