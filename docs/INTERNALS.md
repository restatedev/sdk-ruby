# Restate Ruby SDK — Internals

This document describes the internal architecture, execution flow, and important implementation
details of the Restate Ruby SDK. It is intended for contributors and AI assistants working on
the codebase.

---

## Architecture Overview

```
  Restate Runtime
      │ HTTP/2 (BidiStream protocol)
      ▼
  Falcon (HTTP/2 server, fiber-based via Async)
      │ Rack 3 interface
      ▼
  Restate::Server                    ← lib/restate/server.rb
      │ routes requests, manages streaming I/O
      ▼
  Restate::ServerContext             ← lib/restate/server_context.rb
      │ progress loop, context API for handlers
      ▼
  Restate::VMWrapper                 ← lib/restate/vm.rb
      │ maps native types to Ruby types
      ▼
  Restate::Internal::VM              ← ext/restate_internal/src/lib.rs
      │ Magnus (Ruby ↔ Rust FFI)
      ▼
  restate-sdk-shared-core            (Rust crate, protocol state machine)
```

The SDK is a Rack 3 application designed for Falcon. It wraps the shared Rust
`restate-sdk-shared-core` VM — the same core used by the Python, TypeScript, and other SDKs.

---

## File Map

```
lib/
├── restate.rb                       Factory methods: Restate.service/virtual_object/workflow/endpoint
└── restate/
    ├── context.rb                   Request = Struct.new(:id, :headers, :body)
    ├── discovery.rb                 Generates discovery JSON manifest
    ├── durable_future.rb            DurableFuture, DurableCallFuture, SendHandle
    ├── endpoint.rb                  Endpoint — holds services, builds Rack app
    ├── errors.rb                    TerminalError, SuspendedError, InternalError, DisconnectedError
    ├── handler.rb                   Handler, HandlerIO, ServiceTag structs + invoke_handler
    ├── serde.rb                     JsonSerde, BytesSerde, TStructSerde, DryStructSerde, serde resolution
    ├── server.rb                    Rack 3 app — routes, I/O streaming, Async tasks
    ├── server_context.rb            ctx object — state, sleep, run, calls, progress loop
    ├── service.rb                   Stateless Service class + handler DSL
    ├── service_dsl.rb               Shared class-level DSL (inherited by all service types)
    ├── virtual_object.rb            VirtualObject class + handler/shared DSL
    ├── testing.rb                   Test harness (opt-in: require 'restate/testing')
    ├── vm.rb                        VMWrapper — Ruby bridge to native VM
    └── workflow.rb                  Workflow class + main/handler DSL

ext/restate_internal/
├── Cargo.toml                       Depends on restate-sdk-shared-core 0.7.0, magnus 0.7
└── src/lib.rs                       Rust ↔ Ruby bindings (~1095 lines)

spec/
├── spec_helper.rb                   Minimal RSpec config
└── harness_spec.rb                  Integration tests using Restate::Testing harness

test-services/                       Integration test services (for sdk-test-suite)
├── Dockerfile                       Multi-stage: build native ext → run Falcon
├── config.ru                        Rack entry point
├── services.rb                      Service registry + SERVICES env filter
├── exclusions.yaml                  Test suite exclusions (currently empty — all tests pass)
└── services/                        12 test service files (see Test Services section)

examples/                            Runnable examples showcasing SDK features
├── config.ru                        Rackup: loads and serves all examples
├── greeter.rb                       Hello World: simplest stateless service
├── durable_execution.rb             ctx.run, RunRetryPolicy, TerminalError
├── virtual_objects.rb               State ops, handler vs shared
├── workflow.rb                      Promises, signals, workflow state
├── service_communication.rb         Calls, sends, fan-out, wait_any, awakeables
└── typed_handlers.rb               Dry::Struct input/output, JSON Schema generation
```

---

## Components

### Native Extension (`ext/restate_internal/src/lib.rs`)

A Rust crate compiled via `rb_sys` + `magnus` into a Ruby native extension loaded as
`require "restate_internal"`. It exposes:

- **`Restate::Internal::VM`** — wraps `CoreVM`. All protocol logic lives in the Rust core;
  Ruby just drives it.
- **Data types** — `Header`, `ResponseHead`, `Failure`, `Input`, `CallHandle`,
  `ExponentialRetryConfig`, progress response types (`DoProgressAnyCompleted`,
  `DoProgressReadFromInput`, `DoProgressExecuteRun`, `DoProgressCancelSignalReceived`,
  `DoWaitForPendingRun`, `Suspended`), `Void`, `StateKeys`.
- **`IdentityVerifier`** — verifies request identity signatures.
- **Error formatter** — provides Ruby-specific error messages (e.g., warning about bare
  `rescue` catching `SuspendedError`).

The init function **must** be annotated `#[magnus::init(name = "restate_internal")]` to match
the `require` path. Without the explicit name, Magnus derives the symbol from the crate name
which may include hyphens.

### VMWrapper (`lib/restate/vm.rb`)

Thin Ruby wrapper that:
1. Creates a `Internal::VM` with request headers.
2. Delegates all `sys_*` calls.
3. Maps native result types to Ruby-side types (e.g., `Internal::Suspended` → `Restate::Suspended`,
   `Internal::Failure` → `Restate::Failure`).
4. Catches `Internal::VMError` from `do_progress`/`take_notification` and returns it as a value
   (not raised), so `ServerContext` can handle it.

**Key types defined here:**
- `Invocation` Struct: `{invocation_id, random_seed, headers, input_buffer, key}`
- `Failure` Struct: `{code, message, stacktrace}`
- `RunRetryPolicy` Struct: `{initial_interval, max_attempts, max_duration, max_interval, interval_factor}`
- Frozen sentinel singletons: `NOT_READY`, `SUSPENDED`, `DO_PROGRESS_ANY_COMPLETED`,
  `DO_PROGRESS_READ_FROM_INPUT`, `DO_PROGRESS_CANCEL_SIGNAL_RECEIVED`, `DO_WAIT_PENDING_RUN`
- `DoProgressExecuteRun` Struct: `{handle}` — carries the run handle to execute

### Server (`lib/restate/server.rb`)

Rack 3 application with three routes:

| Method | Path                         | Handler              |
|--------|------------------------------|----------------------|
| GET    | `/health`                    | `health_response`    |
| GET    | `/discover`                  | `handle_discover`    |
| POST   | `/invoke/:service/:handler`  | `handle_invocation`  |

#### Discovery

Negotiates protocol version from the `Accept` header (v2, v3, v4). Auto-detects protocol mode
from HTTP version (HTTP/2 → `BIDI_STREAM`, HTTP/1.1 → `REQUEST_RESPONSE`), or uses the endpoint's
forced protocol setting.

#### Invocation Flow

This is the most complex part. See [Invocation Execution Flow](#invocation-execution-flow) below.

### ServerContext (`lib/restate/server_context.rb`)

The context object accessed via fiber-local accessors (e.g., `Restate.current_context`). Implements:

- **Fiber-local context storage** — `enter` sets the current context, service kind, and handler
  kind in fiber-local storage (`Thread.current[:restate_context]`, `:restate_service_kind`,
  `:restate_handler_kind`) before invoking the handler, and clears them in an `ensure` block.
  This enables `Restate.current_context` and the type-specific accessors to retrieve the context
  from anywhere within the handler's fiber. Each accessor validates both service kind and handler
  kind at runtime. The context hierarchy provides type safety:
  - `Context` — base (run, sleep, calls, awakeables)
  - `ObjectSharedContext` — read-only state (get, state_keys, key)
  - `ObjectContext` — full state (+ set, clear, clear_all)
  - `WorkflowSharedContext` — read-only state + promises
  - `WorkflowContext` — full state + promises
- **Progress loop** (`poll_or_cancel`) — the core execution driver.
- **Public context API** — `get`, `set`, `clear`, `clear_all`, `state_keys`, `sleep`, `run`,
  `run_sync`, `service_call`, `service_send`, `object_call`, `object_send`, `workflow_call`,
  `workflow_send`, `generic_call`, `generic_send`, `promise`, `peek_promise`, `resolve_promise`,
  `reject_promise`, `awakeable`, `resolve_awakeable`, `reject_awakeable`, `cancel_invocation`,
  `wait_any`.
- **Low-level handle API** (used by test services) — `resolve_handle`, `wait_any_handle`,
  `completed?`, `take_completed`.
- **Run execution** — spawns durable side effects as Async child tasks. `run` uses fibers by
  default; pass `background: true` to offload to a real OS Thread via `offload_to_thread`
  (IO.pipe-based fiber yield). `run_sync` is a shortcut for `run(...).await`.

### Service Types

All three share a common DSL defined in `lib/restate/service_dsl.rb`:

- **`Service`** (`lib/restate/service.rb`) — stateless, handlers have no `kind`.
- **`VirtualObject`** (`lib/restate/virtual_object.rb`) — keyed + stateful, handlers default to
  `:exclusive`. Has `shared` method for concurrent-access handlers.
- **`Workflow`** (`lib/restate/workflow.rb`) — keyed + stateful, has `.main()` (kind=workflow,
  runs once per key) and `.handler()` (kind=shared).

### Service DSL (`lib/restate/service_dsl.rb`)

The shared class-level DSL included by all service types:

- `inherited(subclass)` — initializes `@_handler_registry`, `@_service_name`, `@_handlers`
- `service_name(name = nil)` — getter/setter; defaults to unqualified class name
- `service_tag` → `ServiceTag` — built from `service_name` and `_service_kind`
- `handlers` → `Hash[String, Handler]` — lazy-built, cached
- `_register_handler(method_name, kind:, **opts)` — stores in registry, invalidates cache
- `_build_handlers` — reflects on instance methods, binds to `.allocate` instances, creates
  Handler structs. Uses `Serde.resolve(meta[:input])` / `Serde.resolve(meta[:output])` to
  convert `input:`/`output:` options into serde objects with schema

**Handler binding**: The DSL uses `instance_method(name).bind_call(allocate, ...)` pattern. This
creates a lightweight uninitialized instance for method dispatch. Handlers are stateless — any
instance state should go through `ctx.get`/`ctx.set`.

### Handler Dispatch (`lib/restate/handler.rb`)

`Restate.invoke_handler` deserializes input via `handler_io.input_serde`, calls the block with
`()` or `(input)` based on arity, then serializes output via `handler_io.output_serde`.

**Data structures:**
- `ServiceTag` = `Struct.new(:kind, :name, :description, :metadata)`
- `HandlerIO` = `Struct.new(:accept, :content_type, :input_serde, :output_serde)` — schema lives
  on the serde objects (accessed via `input_serde.json_schema`), not as separate fields.
- `Handler` = `Struct.new(:service_tag, :handler_io, :kind, :name, :callable, :arity)`

### Durable Futures (`lib/restate/durable_future.rb`)

Three classes for async result handling:

**`DurableFuture`** — returned by `ctx.sleep`, `ctx.run`, promise operations.
- `await` — first call resolves via `ctx.resolve_handle(handle)`, subsequent calls return cached value
- `completed?` — non-blocking check via `ctx.completed?(handle)`
- `handle` — the raw VM notification handle (Integer)

**`DurableCallFuture` < `DurableFuture`** — returned by `ctx.service_call`, `ctx.object_call`, `ctx.workflow_call`.
- Two handles: `result_handle` (for await) and `invocation_id_handle` (for ID)
- `invocation_id` — lazily resolved on first access
- `cancel` — calls `ctx.cancel_invocation(invocation_id)`

**`SendHandle`** — returned by `ctx.service_send`, `ctx.object_send`, `ctx.workflow_send`.
- `invocation_id` — lazily resolved
- `cancel` — calls `ctx.cancel_invocation(invocation_id)`
- No `await` (fire-and-forget)

### AttemptFinishedEvent

Available via `ctx.request.attempt_finished_event`. Signals when the current invocation attempt
is about to finish (e.g., connection closing). Two methods:

- **`set?`** — non-blocking check, returns `true` if the attempt has finished.
- **`wait`** — blocks the current fiber until the attempt finishes.

Useful for long-running handlers that need to flush work or perform cleanup before the attempt ends.

### Serialization (`lib/restate/serde.rb`)

- **`JsonSerde`** — default. `JSON.generate` / `JSON.parse(buf, symbolize_names: false)`.
  Serializes nil as empty string (not `"null"`). Has `json_schema` returning nil.
- **`BytesSerde`** — pass-through for raw bytes. Has `json_schema` returning nil.
- **`NOT_SET`** — frozen sentinel to distinguish "caller didn't pass serde" from `nil`.
- **`Serde.resolve(type_or_serde)`** — resolves a type class or serde object into a serde
  with `serialize`/`deserialize`/`json_schema`. Priority: already a serde → use directly;
  `T::Struct` subclass → `TStructSerde`; `Dry::Struct` subclass → `DryStructSerde`;
  primitive type → `TypeSerde` with schema; class with `.json_schema` → `TypeSerde`;
  fallback → `JsonSerde`.
- **`TypeSerde`** — wraps a primitive type or custom-schema class. Delegates to `JsonSerde`
  for serialize/deserialize, adds `json_schema` from the type.
- **`TStructSerde`** — for `T::Struct` subclasses (Sorbet). Deserializes JSON via
  `T::Struct.from_hash`, serializes via `T::Struct#serialize`. Generates JSON Schema by
  introspecting Sorbet `T::Types` (handles `Simple`, `Union`/nilable, `TypedArray`,
  `TypedHash`, nested structs).
- **`DryStructSerde`** — for `Dry::Struct` subclasses. Deserializes JSON into struct instances
  via `Struct.new(**hash)`, serializes via `to_h` + `JSON.generate`. Generates JSON Schema
  by introspecting dry-types (handles Nominal, Sum/optional, Array::Member, Constrained,
  nested structs).
- **`PRIMITIVE_SCHEMAS`** — maps Ruby classes to JSON Schema hashes.

### Error Types (`lib/restate/errors.rb`)

| Class | Purpose | User-facing? |
|-------|---------|-------------|
| `TerminalError` | Non-retryable failure (has `status_code`, default 500) | Yes |
| `SuspendedError` | VM suspended, handler must stop | No (control flow) |
| `InternalError` | VM error, triggers retry | No (control flow) |
| `DisconnectedError` | HTTP connection lost | No (control flow) |

`SuspendedError` and `InternalError` are dangerous because bare `rescue => e` in user handlers
will catch them. `ServerContext#enter` walks the exception cause chain to detect this.

### Discovery (`lib/restate/discovery.rb`)

Generates the JSON manifest returned at `GET /discover`. Maps internal types to protocol types:
- Service kinds: `service`→`SERVICE`, `object`→`VIRTUAL_OBJECT`, `workflow`→`WORKFLOW`
- Handler kinds: `exclusive`→`EXCLUSIVE`, `shared`→`SHARED`, `workflow`→`WORKFLOW`
- Protocol mode: `bidi`→`BIDI_STREAM`, `request_response`→`REQUEST_RESPONSE`
- Protocol versions: min=5, max=5

### Test Harness (`lib/restate/testing.rb`)

Opt-in module (`require 'restate/testing'`) that provides self-contained integration testing.
Three components:

1. **SDK Server** — Falcon in a background `Thread` with its own `Async` event loop. Finds a free
   port via `TCPServer.new('0.0.0.0', 0)`, starts `Falcon::Server` with the Rack app, and polls
   TCP connect for readiness.

2. **Restate Container** — `RestateContainer` subclass of `Testcontainers::DockerContainer` that
   overrides `_container_create_options` to inject `ExtraHosts: ["host.docker.internal:host-gateway"]`.
   This lets the container reach the host-bound SDK server. Exposed ports 8080 (ingress) and 9070
   (admin) are mapped to random host ports. Environment variables match the Python harness
   configuration (partition config, invoker timeouts, always_replay, disable_retries).

3. **Registration** — `Net::HTTP` POST to `{admin_url}/deployments` with the SDK URL
   (`http://host.docker.internal:{port}`).

Cleanup kills the server thread and force-stops/removes the container.

---

## Invocation Execution Flow

When Restate invokes a handler, the following happens:

### Phase 1: Input Ingestion

```
HTTP/2 request body (streaming)
    │
    ▼
rack.input.read_partial(16384)  ──► vm.notify_input(chunk)
    │                                    │
    │                            vm.is_ready_to_execute?
    │                                    │
    ├── not ready yet ◄─── false ────────┘
    │       └── loop back to read_partial
    │
    └── ready ◄──────── true ────────────┘
            └── break out of loop
```

**CRITICAL**: Must use `read_partial`, NOT `read`. See [Important Learnings](#important-learnings).

### Phase 2: Setup

After the VM is ready:
1. `vm.sys_input` returns the `Invocation` (id, headers, input buffer, key).
2. A background **input reader** Async task continues reading remaining HTTP body into
   `input_queue`.
3. A `ServerContext` is created with the VM, handler, invocation, output callback, and input queue.

### Phase 3: Handler Execution (Async task)

```
Async task:
    context.enter()
        │
        ▼
    invoke_handler(handler, ctx, input_buffer)
        │
        ▼ (handler calls ctx.get, ctx.run, ctx.service_call, etc.)
        │
    Each ctx method calls vm.sys_* then poll_and_take(handle)
        │
        ▼
    poll_or_cancel (progress loop)
```

### Phase 4: Progress Loop

```
loop:
    flush_output()  ──► drain vm.take_output → output_queue
        │
        ▼
    vm.do_progress(handles)
        │
        ├── AnyCompleted        → return (handle is done)
        ├── ReadFromInput       → dequeue from input_queue
        │       ├── String      → vm.notify_input(chunk)
        │       ├── :eof        → vm.notify_input_closed
        │       ├── :disconnected → raise DisconnectedError
        │       └── :run_completed → next iteration
        ├── DoWaitPendingRun    → same as ReadFromInput
        ├── ExecuteRun(handle)  → spawn Async task for run block
        ├── CancelSignalReceived → raise TerminalError(409)
        └── Suspended           → raise SuspendedError
```

### Phase 5: Output Streaming

Output flows through two paths:

1. **During handler execution**: `flush_output()` in the progress loop drains the VM and enqueues
   chunks to `output_queue`.
2. **After handler completes**: The handler Async task drains any remaining VM output, then
   enqueues `nil` to signal end-of-stream.

The `StreamingBody` (Rack 3 body) sits on the other end of `output_queue`, yielding chunks to
Falcon as they arrive:

```
vm.take_output → output_queue.enqueue(chunk) ··· output_queue.dequeue → yield to Falcon → HTTP/2
```

### Concurrency Diagram

```
┌─────────────────────────────────────────────────────────┐
│  Falcon Fiber (HTTP request)                            │
│                                                         │
│  1. Read initial input → VM ready                       │
│  2. Spawn background input reader (Async task A)        │
│  3. Spawn handler execution (Async task B)              │
│  4. Return [status, headers, StreamingBody]             │
│     └── StreamingBody.each blocks on output_queue       │
└─────────────────────────────────────────────────────────┘

┌──────────────────────────┐  ┌──────────────────────────┐
│  Async Task A:           │  │  Async Task B:           │
│  Input Reader            │  │  Handler + Progress Loop │
│                          │  │                          │
│  loop:                   │  │  context.enter()         │
│    chunk = read_partial  │  │    invoke_handler(...)   │
│    input_queue << chunk  │  │    poll_or_cancel:       │
│  ensure:                 │  │      flush_output → out_q│
│    input_queue << :eof   │  │      do_progress         │
│                          │  │      input_q.dequeue     │
│                          │  │  drain remaining output  │
│                          │  │  output_queue << nil     │
└──────────────────────────┘  └──────────────────────────┘
```

---

## VM State Machine

The VM is a synchronous state machine. It does not do I/O itself. The SDK drives it:

1. Feed input bytes → `notify_input(bytes)` / `notify_input_closed()`
2. Check readiness → `is_ready_to_execute()`
3. Get invocation → `sys_input()`
4. Issue syscalls → `sys_get_state`, `sys_run`, `sys_call`, etc. (returns handles)
5. Drive progress → `do_progress(handles)` (tells you what to do next)
6. Collect results → `take_notification(handle)` (gets completed values)
7. Drain output → `take_output()` (gets bytes to send back over HTTP/2)
8. Finish → `sys_write_output_success/failure` then `sys_end`

The VM is wrapped in `RefCell<CoreVM>` — it is not thread-safe. All access must happen within
the same fiber chain (which is guaranteed by Async's cooperative scheduling).

### VM Syscalls Reference

| Method | Returns | Description |
|--------|---------|-------------|
| `sys_input` | `Invocation` | Get invocation metadata (id, headers, input, key) |
| `sys_get_state(name)` | handle | Read state key |
| `sys_set_state(name, value)` | — | Write state key (immediate, no handle) |
| `sys_clear_state(name)` | — | Delete state key |
| `sys_clear_all_state` | — | Delete all state keys |
| `sys_get_state_keys` | handle | List all state key names |
| `sys_sleep(millis, name?)` | handle | Create sleep timer |
| `sys_call(service, handler, param, key?, idempotency_key?, headers?)` | `CallHandle` | RPC call (two handles: result + invocation_id) |
| `sys_send(service, handler, param, key?, delay?, idempotency_key?, headers?)` | handle | Fire-and-forget send (invocation_id handle only) |
| `sys_run(name)` | handle | Register durable side effect |
| `propose_run_completion_success(handle, output)` | — | Mark run as succeeded |
| `propose_run_completion_failure(handle, failure)` | — | Mark run as terminally failed |
| `propose_run_completion_transient(handle, failure, duration_ms, config)` | — | Mark run as transiently failed (retryable) |
| `sys_awakeable` | `[id, handle]` | Create awakeable callback |
| `sys_complete_awakeable_success(id, value)` | — | Resolve awakeable |
| `sys_complete_awakeable_failure(id, failure)` | — | Reject awakeable |
| `sys_get_promise(name)` | handle | Get promise value (blocks until resolved) |
| `sys_peek_promise(name)` | handle | Peek promise (non-blocking) |
| `sys_complete_promise_success(name, value)` | handle | Resolve promise |
| `sys_complete_promise_failure(name, failure)` | handle | Reject promise |
| `sys_cancel_invocation(id)` | — | Cancel invocation |
| `sys_write_output_success(output)` | — | Write final handler result |
| `sys_write_output_failure(failure)` | — | Write final handler error |
| `sys_end` | — | Finalize invocation |
| `is_replaying` | bool | Check if replaying from journal |

---

## Typed Call Resolution

When a handler calls `ctx.service_call(Worker, :process, arg)`, the `resolve_call_target` method:

1. Checks if `service` is a Class with `respond_to?(:service_name)`
2. If yes: extracts `service.service_name`, looks up `service.handlers[handler_name]` for metadata
3. If no (string): uses `service.to_s` and `handler.to_s`, metadata is nil

The `resolve_serde` method then picks serializers in order:
1. Explicit serde passed by caller (if not `NOT_SET` sentinel)
2. Handler metadata's `input_serde`/`output_serde` (if metadata available)
3. `JsonSerde` as final fallback

This means: when you pass class references, the SDK auto-resolves serdes from the target handler's
registration options. When you pass strings, it always uses `JsonSerde`.

---

## Run Execution (Durable Side Effects)

When user code calls `ctx.run('name') { ... }`:

1. `sys_run(name)` registers the run with the VM, returns a handle
2. The action block is stored in `@run_coros_to_execute[handle]`
3. A `DurableFuture` wrapping the handle is returned immediately
4. When the future is awaited, the progress loop eventually receives `DoProgressExecuteRun(handle)`
5. The progress loop spawns an Async task that:
   - Executes the stored action block
   - On success: calls `propose_run_completion_success(handle, serialized_result)`
   - On `TerminalError`: calls `propose_run_completion_failure(handle, failure)`
   - On other errors: calls `propose_run_completion_transient(handle, failure, duration, config)`
   - Enqueues `:run_completed` to `input_queue` to wake the progress loop
6. The progress loop continues and eventually `AnyCompleted` is returned for the handle

**During replay**, the VM already has the result from the journal. `do_progress` returns
`AnyCompleted` directly — the action block is never executed.

### Background Runs (`background: true`)

With Async 2.x and Ruby 3.1+, the Fiber Scheduler intercepts most blocking I/O automatically
(Net::HTTP, TCPSocket, file reads, etc.), so `ctx.run` already handles I/O-bound work without
blocking the event loop. `background: true` is only needed for CPU-heavy native extensions
that release the GVL (e.g., image processing with libvips, crypto with OpenSSL).

`ctx.run('name', background: true) { ... }` offloads the block to `BackgroundPool`, a shared
fixed-size thread pool (default 8 workers, configurable via `RESTATE_BACKGROUND_POOL_SIZE`).

The mechanism uses `offload_to_thread`:
1. Creates an `IO.pipe`
2. Submits the action to the `BackgroundPool` thread pool
3. The pool worker runs the action and closes the write end on completion
4. The fiber calls `read_io.read(1)`, which yields the fiber in Async context
5. When the worker closes the pipe, the fiber resumes
6. VM calls (`propose_run_completion_*`) happen on the fiber, preserving thread safety

### `run_sync`

`ctx.run_sync(...)` is a convenience shortcut for `ctx.run(...).await`. It accepts all the
same parameters (including `background: true`) and returns the value directly.

---

## Test Services (`test-services/`)

The `test-services/` directory contains integration test services designed to run against the
[sdk-test-suite](https://github.com/restatedev/sdk-test-suite) (JVM-based e2e verification runner).

### All Services

| Service | Type | Key Handlers |
|---------|------|-------------|
| Counter | VirtualObject | reset, get, add, addThenFail |
| ListObject | VirtualObject | append, get, clear |
| MapObject | VirtualObject | set, get, clearAll |
| Failing | VirtualObject | terminallyFailingCall, sideEffectSucceedsAfterGivenAttempts, ... |
| NonDeterministic | VirtualObject | setDifferentKey, callDifferentMethod, ... |
| TestUtilsService | Service | echo, uppercaseEcho, echoHeaders, rawEcho, countExecutedSideEffects, sleepConcurrently, cancelInvocation |
| Proxy | Service | call, oneWayCall, manyCalls |
| AwakeableHolder | VirtualObject | hold, hasAwakeable, unlock |
| CancelTestRunner | Service | startTest, verifyTest |
| CancelTestBlockingService | Service | block, isUnlocked |
| KillTestRunner | Service | startCallTree |
| KillTestSingleton | VirtualObject | recursiveCall, isUnlocked |
| BlockAndWaitWorkflow | Workflow | run (main), unblock, getState |
| VirtualObjectCommandInterpreter | VirtualObject | interpretCommands, getResults, hasAwakeable, resolveAwakeable, rejectAwakeable |

### Test Suite Exclusions

Currently `exclusions.yaml` has no exclusions — all test suites pass with no skipped tests.

### Running Integration Tests

```bash
# Full run (builds Docker image, downloads test JAR, runs all suites)
./etc/run-integration-tests.sh

# Skip Docker build (reuse existing image)
./etc/run-integration-tests.sh --skip-build
```

Requires Docker and Java 21+. The test JAR is cached in `tmp/`.

### Harness Tests (`spec/harness_spec.rb`)

Separate from the sdk-test-suite, these use `Restate::Testing` to test services in-process.
Three tests cover stateless services, virtual object state persistence, and service-to-service
calls.

```bash
make test-harness  # or: bundle exec rspec spec/harness_spec.rb
```

Requires Docker only (no Java).

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SERVICES` | Comma-separated list of service names to register (default: all) |
| `E2E_REQUEST_SIGNING_ENV` | Identity signing key for request verification |
| `PORT` | Listen port (default: 9080) |
| `RESTATE_CORE_LOG` | Rust core log level (default: debug) |
| `RESTATE_LOGGING` | Alias for `RESTATE_CORE_LOG` (used by e2e runner) |

---

## Manual Testing

### Prerequisites

1. **Restate runtime** must be running (default ingress on `:8080`, admin API on `:9070`).
2. **Native extension** must be compiled: `bundle exec rake compile`.

### Start the Example Server

```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080
```

Use `-n 1` for a single worker (easier debugging).

### Register the Deployment

```bash
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080"}'
```

To force re-registration after code changes:
```bash
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080", "force": true}'
```

### Invoke Handlers

```bash
# Greeter (stateless service)
curl localhost:8080/Greeter/greet -H 'content-type: application/json' -d '"World"'

# Counter (virtual object — key in URL)
curl localhost:8080/Counter/my-counter/add -H 'content-type: application/json' -d '3'
curl localhost:8080/Counter/my-counter/get -H 'content-type: application/json' -d 'null'

# Signup (workflow — key in URL)
curl localhost:8080/Signup/user1/run -H 'content-type: application/json' -d '"user@example.com"'
```

### Troubleshooting

- **Falcon not responding to curl**: Falcon uses HTTP/2. Use `--http2-prior-knowledge` or go
  through the Restate ingress (port 8080) which handles protocol negotiation.
- **Worker crashes on startup**: Check Falcon logs (JSON to stdout). Common cause: Sorbet runtime
  `NameError` from eager sig evaluation — ensure all types referenced in sigs are loaded.
- **Port stuck after crash**: `lsof -ti :9080 | xargs kill -9`
- **Restate can't reach Falcon**: If Restate runs in Docker, bind Falcon to `0.0.0.0` not
  `localhost`, and use the host machine's IP in the registration URI.

---

## Important Learnings

### 1. `read_partial` vs `read` on Falcon's `rack.input`

Falcon's `rack.input` is a `Protocol::Rack::Input` backed by `IO::Stream::Readable`.

- **`read(n)`** loops calling `fill_read_buffer` until the buffer has `n` bytes or EOF. On a
  streaming HTTP/2 body where initial data is ~250 bytes and the stream stays open,
  `read(16384)` **blocks forever**.
- **`read_partial(n)`** calls `fill_read_buffer` once and returns whatever is available.

This is the Ruby equivalent of Python's ASGI `receive()` which naturally returns chunks as they
arrive.

### 2. `take_output` Can Return Empty Strings

The Rust VM's `take_output` returns `TakeOutputResult::Buffer(bytes)` where bytes can be empty
(0 length). The Magnus binding converts this to Ruby `""`. In Ruby, empty string is **truthy**,
so naive checks like `break unless output` create infinite loops.

**Always use**: `break if output.nil? || output.empty?`

This applies in two places:
- `ServerContext#flush_output` (progress loop output drain)
- `Server#process_invocation` (final output drain after handler completes)

### 3. Async::Queue, Not Thread::Queue

The SDK runs on Async fibers, not OS threads. `Thread::Queue` blocks the OS thread (and the
entire event loop). `Async::Queue` yields the fiber, allowing other fibers to run.

- `Async::Queue` uses `enqueue` / `dequeue` (not `push` / `pop`).
- The `input_queue` multiplexes several signal types: `String` (body chunk), `:eof`,
  `:disconnected`, `:run_completed`.

### 4. Magnus Init Symbol

The native extension init function must specify the exact module name:
```rust
#[magnus::init(name = "restate_internal")]
```
Without this, Magnus derives the symbol from the Cargo crate name, which may not match what
Ruby expects from `require "restate_internal"`.

### 5. Binary String Encoding

All byte buffers passed to the VM must be ASCII-8BIT encoded. Call `.b` on strings before
passing them to `notify_input`, `sys_set_state`, `sys_write_output_success`, etc.

### 6. Error Handling in Handlers

`SuspendedError` and `InternalError` are internal control flow exceptions. User handlers that
use bare `rescue => e` will accidentally catch these. The `ServerContext#enter` method walks the
exception cause chain to detect wrapped internal exceptions.

### 7. `Internal::Failure.new` Requires 3 Arguments

`Internal::Failure.new(code, message, stacktrace)` — the stacktrace is required (pass `nil`
if not available). Missing it causes `ArgumentError` which gets treated as a transient error,
making terminal errors retry forever.

### 8. Falcon Process Management

Falcon forks worker processes. When a worker dies (e.g., health check timeout after 30s), the
parent process survives and holds the port. To fully restart:
```bash
lsof -ti :9080 | xargs kill -9
```

Use `-n 1` flag for single worker during development.

### 9. Sorbet Eager Sig Evaluation

Sorbet sigs are evaluated eagerly at class load time. If a sig references a class that hasn't
been `require`d yet, you get `NameError` at runtime (even though `srb tc` passes). Fix: use
`T.untyped` for return types of methods that lazy-load their dependencies.
