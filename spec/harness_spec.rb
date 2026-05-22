# frozen_string_literal: true

require "spec_helper"
require "restate"
require "restate/testing"
require "dry-struct"
require "net/http"
require "json"
require "securerandom"

module Types
  include Dry.Types()
end

class GreetingRequest < Dry::Struct
  attribute :name, Types::String
  attribute? :greeting, Types::String
end

# ── Test services (defined inline) ──────────────────────────

class TestGreeter < Restate::Service
  handler :greet
  def greet(name)
    Restate.run("build-greeting") { "Hello, #{name}!" }.await
  end
end

class TestCounter < Restate::VirtualObject
  handler def add(addend)
    old_value = Restate.get("count") || 0
    new_value = old_value + addend
    Restate.set("count", new_value)
    {"oldValue" => old_value, "newValue" => new_value}
  end

  shared def get
    Restate.get("count") || 0
  end
end

class TestWorker < Restate::Service
  handler def process(input)
    Restate.run("do-work") { "processed:#{input}" }.await
  end
end

class TestOrchestrator < Restate::Service
  handler def orchestrate(input)
    result = Restate.service_call(TestWorker, :process, input).await
    "orchestrated:#{result}"
  end
end

class TestRunSync < Restate::Service
  handler def compute(input)
    result = Restate.run_sync("heavy-computation") { input * 2 }
    "result:#{result}"
  end
end

class TestFiberLocalCtx < Restate::Service
  handler def process(input)
    # Access Restate API from a nested method via top-level Restate module
    do_work(input)
  end

  private

  def do_work(input)
    result = Restate.run_sync('step') { "processed:#{input}" }
    "fiber_local:#{result}"
  end
end

class TypedGreeter < Restate::Service
  handler :greet, input: GreetingRequest, output: String
  def greet(request)
    greeting = request.greeting || "Hello"
    "#{greeting}, #{request.name}!"
  end
end

# Middleware that stores a header value in fiber-local storage so the handler can read it.
class TestHeaderMiddleware
  def call(handler, ctx)
    team_id = ctx.request.headers['x-team-id']
    Thread.current[:test_team_id] = team_id
    yield
  ensure
    Thread.current[:test_team_id] = nil
  end
end

class MiddlewareTestService < Restate::Service
  handler def check_header
    team = Thread.current[:test_team_id] || 'none'
    "team:#{team}"
  end
end

# ── Outbound middleware test services ─────────────────────────

# Outbound middleware: injects x-custom-tag into every outgoing call/send.
class TestOutboundMiddleware
  def call(_service, _handler, headers)
    headers['x-custom-tag'] = 'injected-by-outbound'
    yield
  end
end

# Target service: reads x-custom-tag from inbound headers (set by outbound middleware on the caller side).
class OutboundTargetService < Restate::Service
  handler def read_tag
    tag = Restate.request.headers['x-custom-tag'] || 'missing'
    "tag:#{tag}"
  end
end

# Caller service: calls OutboundTargetService. The outbound middleware should inject the header.
class OutboundCallerService < Restate::Service
  handler def call_target
    OutboundTargetService.call.read_tag.await
  end
end

# ── Declarative state test services ───────────────────────────

class TestDeclCounter < Restate::VirtualObject
  state :count, default: 0

  handler def add(addend)
    self.count += addend
  end

  shared def get
    count
  end

  handler def reset
    clear_count
    'reset'
  end
end

# ── Fluent call API test services ─────────────────────────────

class TestFluentWorker < Restate::Service
  handler def process(task)
    Restate.run_sync('do-work') { "done:#{task}" }
  end
end

class TestFluentOrchestrator < Restate::Service
  handler def orchestrate(input)
    # Use fluent call API
    result = TestFluentWorker.call.process(input).await
    "orchestrated:#{result}"
  end

  handler def fire_and_forget(input)
    # Use fluent send API
    TestFluentWorker.send!.process(input)
    'sent'
  end

  handler def call_object(input)
    # Use fluent call on virtual object
    result = TestDeclCounter.call(input['key']).add(input['value']).await
    "counter:#{result}"
  end
end

# ── Combinator test services ──────────────────────────────────

class TestCombinators < Restate::Service
  handler def all_runs(_input)
    futures = (1..3).map { |i| Restate.run("step-#{i}") { i * 10 } }
    Restate.all(*futures).await
  end

  handler def all_empty(_input)
    Restate.all.await
  end

  handler def race_runs(_input)
    fast = Restate.run('fast') { 'fast-result' }
    slow = Restate.run('slow') { 'slow-result' }
    Restate.race(fast, slow).await
  end

  handler def race_sleep_vs_value(_input)
    quick = Restate.run('quick') { 'value' }
    slow_timer = Restate.sleep(60)
    Restate.race(quick, slow_timer).await
  end

  handler def all_short_circuits(_input)
    ok = Restate.run('ok') { 'ok' }
    bad = Restate.run('bad') { raise Restate::TerminalError.new('boom', status_code: 418) }
    Restate.all(ok, bad).await
  end

  # Composes a race of an all-combinator and a sleep — exercises the tree being
  # passed end-to-end through the shared-core's cooperative-suspension logic.
  handler def race_of_all_vs_sleep(_input)
    a = Restate.run('a') { 'A' }
    b = Restate.run('b') { 'B' }
    inner = Restate.all(a, b)            # CombinedFuture
    Restate.race(inner, Restate.sleep(60)).await
  end

  # all-of-races: each inner race resolves quickly, outer all returns both.
  handler def all_of_races(_input)
    left = Restate.race(Restate.run('l1') { 'L1' }, Restate.run('l2') { 'L2' })
    right = Restate.race(Restate.run('r1') { 'R1' }, Restate.run('r2') { 'R2' })
    Restate.all(left, right).await
  end
end

# ── Signal test services ──────────────────────────────────────

class TestSignal < Restate::Service
  handler def wait_for_signal(name)
    Restate.signal(name).await
  end

  handler def wait_for_two
    a = Restate.signal('signalA').await
    b = Restate.signal('signalB').await
    { 'a' => a, 'b' => b }
  end

  handler def resolve_signal(req)
    Restate.resolve_signal(req['invocation_id'], req['name'], req['value'])
    'ok'
  end

  handler def reject_signal(req)
    Restate.reject_signal(req['invocation_id'], req['name'], req['reason'])
    'ok'
  end
end

# ── Helpers ──────────────────────────────────────────────────

def post_json(base_url, path, body, headers: {})
  uri = URI("#{base_url}#{path}")
  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request["idempotency-key"] = SecureRandom.uuid
  headers.each { |k, v| request[k] = v }
  request.body = JSON.generate(body)
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |http| http.request(request) }
end

# Fire-and-forget send via the Restate ingress. Returns the invocation id.
def send_async(base_url, path, body, headers: {})
  response = post_json(base_url, "#{path}/send", body, headers: headers)
  raise "send_async failed: #{response.code} #{response.body}" unless response.code.to_i.between?(200, 299)

  JSON.parse(response.body).fetch('invocationId')
end

# Attach to a running invocation by id and wait for its result.
def attach_invocation(base_url, invocation_id)
  uri = URI("#{base_url}/restate/invocation/#{invocation_id}/attach")
  request = Net::HTTP::Get.new(uri)
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 60) { |http| http.request(request) }
end

# ── Tests ────────────────────────────────────────────────────

RSpec.describe Restate::Testing do
  before(:all) do
    @harness = Restate::Testing::RestateTestHarness.new(
      TestGreeter, TestCounter, TestWorker, TestOrchestrator, TestRunSync, TestFiberLocalCtx,
      TypedGreeter, MiddlewareTestService,
      TestDeclCounter, TestFluentWorker, TestFluentOrchestrator,
      OutboundTargetService, OutboundCallerService,
      TestSignal,
      TestCombinators
    ) do |endpoint|
      endpoint.use(TestHeaderMiddleware)
      endpoint.use_outbound(TestOutboundMiddleware)
    end
    @harness.start
  end

  after(:all) do
    @harness&.stop
  end

  it "invokes a stateless greeter service" do
    response = post_json(@harness.ingress_url, "/TestGreeter/greet", "World")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("Hello, World!")
  end

  it "persists state in a virtual object" do
    key = SecureRandom.hex(8)

    # Add 5 to the counter
    response = post_json(@harness.ingress_url, "/TestCounter/#{key}/add", 5)
    expect(response.code).to eq("200")
    result = JSON.parse(response.body)
    expect(result["oldValue"]).to eq(0)
    expect(result["newValue"]).to eq(5)

    # Read it back
    response = post_json(@harness.ingress_url, "/TestCounter/#{key}/get", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(5)
  end

  it "runs a durable block with run_sync" do
    response = post_json(@harness.ingress_url, "/TestRunSync/compute", 21)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("result:42")
  end

  it "accesses Restate API from nested methods via top-level module" do
    response = post_json(@harness.ingress_url, "/TestFiberLocalCtx/process", "hello")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("fiber_local:processed:hello")
  end

  it "supports service-to-service calls" do
    response = post_json(@harness.ingress_url, "/TestOrchestrator/orchestrate", "hello")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("orchestrated:processed:hello")
  end

  it "handles typed dry-struct input" do
    response = post_json(@harness.ingress_url, "/TypedGreeter/greet", { "name" => "World" })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("Hello, World!")
  end

  it "handles typed dry-struct input with optional field" do
    response = post_json(@harness.ingress_url, "/TypedGreeter/greet",
                         { "name" => "World", "greeting" => "Hi" })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("Hi, World!")
  end

  it "runs handler middleware that extracts headers" do
    response = post_json(@harness.ingress_url, "/MiddlewareTestService/check_header", nil,
                         headers: { "x-team-id" => "acme-corp" })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("team:acme-corp")
  end

  it "runs handler middleware with missing header" do
    response = post_json(@harness.ingress_url, "/MiddlewareTestService/check_header", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("team:none")
  end

  # ── Declarative state ──

  it "uses declarative state getter and setter" do
    key = SecureRandom.hex(8)

    response = post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/add", 10)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(10)

    response = post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/get", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(10)
  end

  it "returns declarative state default when unset" do
    key = SecureRandom.hex(8)

    response = post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/get", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(0)
  end

  it "clears declarative state" do
    key = SecureRandom.hex(8)

    post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/add", 5)

    response = post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/reset", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("reset")

    response = post_json(@harness.ingress_url, "/TestDeclCounter/#{key}/get", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(0)
  end

  # ── Fluent call API ──

  it "uses fluent call API for service-to-service calls" do
    response = post_json(@harness.ingress_url, "/TestFluentOrchestrator/orchestrate", "hello")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("orchestrated:done:hello")
  end

  it "uses fluent send! API for fire-and-forget" do
    response = post_json(@harness.ingress_url, "/TestFluentOrchestrator/fire_and_forget", "hello")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("sent")
  end

  it "uses fluent call API for virtual object calls" do
    key = SecureRandom.hex(8)
    response = post_json(@harness.ingress_url, "/TestFluentOrchestrator/call_object",
                         { "key" => key, "value" => 7 })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("counter:7")
  end

  # ── Outbound middleware ──

  it "injects headers via outbound middleware on service-to-service calls" do
    response = post_json(@harness.ingress_url, "/OutboundCallerService/call_target", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("tag:injected-by-outbound")
  end

  # ── HTTP Client ──

  it "invokes a service via Restate::Client" do
    client = Restate::Client.new(ingress_url: @harness.ingress_url)
    result = client.service("TestGreeter").greet("ClientTest")
    expect(result).to eq("Hello, ClientTest!")
  end

  it "invokes a virtual object via Restate::Client" do
    key = SecureRandom.hex(8)
    client = Restate::Client.new(ingress_url: @harness.ingress_url)

    client.object("TestDeclCounter", key).add(15)
    result = client.object("TestDeclCounter", key).get(nil)
    expect(result).to eq(15)
  end

  it "invokes via Restate.configure + Restate.client" do
    Restate.configure do |c|
      c.ingress_url = @harness.ingress_url
    end

    result = Restate.client.service("TestGreeter").greet("ConfigTest")
    expect(result).to eq("Hello, ConfigTest!")
  end

  # ── Signals ──

  it "resolves a named signal with a value" do
    inv_id = send_async(@harness.ingress_url, "/TestSignal/wait_for_signal", "mySignal")

    response = post_json(@harness.ingress_url, "/TestSignal/resolve_signal",
                         { "invocation_id" => inv_id, "name" => "mySignal", "value" => "hello" })
    expect(response.code).to eq("200")

    result = attach_invocation(@harness.ingress_url, inv_id)
    expect(result.code).to eq("200")
    expect(JSON.parse(result.body)).to eq("hello")
  end

  it "rejects a named signal as a terminal error" do
    inv_id = send_async(@harness.ingress_url, "/TestSignal/wait_for_signal", "mySignal")

    response = post_json(@harness.ingress_url, "/TestSignal/reject_signal",
                         { "invocation_id" => inv_id, "name" => "mySignal", "reason" => "boom" })
    expect(response.code).to eq("200")

    result = attach_invocation(@harness.ingress_url, inv_id)
    expect(result.code).to eq("500")
    expect(result.body).to include("boom")
  end

  # ── Combinators ──

  it "resolves all futures with Restate.all and returns values in input order" do
    response = post_json(@harness.ingress_url, "/TestCombinators/all_runs", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq([10, 20, 30])
  end

  it "returns an empty array when Restate.all is called with no futures" do
    response = post_json(@harness.ingress_url, "/TestCombinators/all_empty", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq([])
  end

  it "returns the first settled future with Restate.race" do
    response = post_json(@harness.ingress_url, "/TestCombinators/race_runs", nil)
    expect(response.code).to eq("200")
    # Either run can win; both produce valid results.
    expect(%w[fast-result slow-result]).to include(JSON.parse(response.body))
  end

  it "races a quick run against a long sleep and resolves with the run" do
    response = post_json(@harness.ingress_url, "/TestCombinators/race_sleep_vs_value", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq('value')
  end

  it "short-circuits Restate.all with the first TerminalError" do
    response = post_json(@harness.ingress_url, "/TestCombinators/all_short_circuits", nil)
    expect(response.code).to eq("418")
    expect(response.body).to include('boom')
  end

  it "composes race(all, sleep) — the inner all wins" do
    response = post_json(@harness.ingress_url, "/TestCombinators/race_of_all_vs_sleep", nil)
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq(%w[A B])
  end

  it "composes all(race, race) — both inner races resolve" do
    response = post_json(@harness.ingress_url, "/TestCombinators/all_of_races", nil)
    expect(response.code).to eq("200")
    body = JSON.parse(response.body)
    expect(body.length).to eq(2)
    expect(%w[L1 L2]).to include(body[0])
    expect(%w[R1 R2]).to include(body[1])
  end

  it "delivers two independently named signals" do
    inv_id = send_async(@harness.ingress_url, "/TestSignal/wait_for_two", nil)

    # Resolve in reverse name order to confirm signals are independent.
    post_json(@harness.ingress_url, "/TestSignal/resolve_signal",
              { "invocation_id" => inv_id, "name" => "signalB", "value" => "b-value" })
    post_json(@harness.ingress_url, "/TestSignal/resolve_signal",
              { "invocation_id" => inv_id, "name" => "signalA", "value" => "a-value" })

    result = attach_invocation(@harness.ingress_url, inv_id)
    expect(result.code).to eq("200")
    expect(JSON.parse(result.body)).to eq("a" => "a-value", "b" => "b-value")
  end
end
