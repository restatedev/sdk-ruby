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

class TStructRequest < T::Struct
  const :name, String
  const :greeting, T.nilable(String)
end

class TStructGreeter < Restate::Service
  handler :greet, input: TStructRequest, output: String
  def greet(request)
    greeting = request.greeting || "Hello"
    "#{greeting}, #{request.name}!"
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

# ── Tests ────────────────────────────────────────────────────

RSpec.describe Restate::Testing do
  before(:all) do
    @harness = Restate::Testing::RestateTestHarness.new(
      TestGreeter, TestCounter, TestWorker, TestOrchestrator, TestRunSync, TestFiberLocalCtx,
      TStructGreeter, TypedGreeter, MiddlewareTestService,
      TestDeclCounter, TestFluentWorker, TestFluentOrchestrator
    ) do |endpoint|
      endpoint.use(TestHeaderMiddleware)
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

  it "handles typed T::Struct input" do
    response = post_json(@harness.ingress_url, "/TStructGreeter/greet", { "name" => "World" })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("Hello, World!")
  end

  it "handles typed T::Struct input with optional field" do
    response = post_json(@harness.ingress_url, "/TStructGreeter/greet",
                         { "name" => "World", "greeting" => "Hey" })
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("Hey, World!")
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
end
