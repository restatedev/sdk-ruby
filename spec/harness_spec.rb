# frozen_string_literal: true

require "spec_helper"
require "restate"
require "restate/testing"
require "net/http"
require "json"
require "securerandom"

# ── Test services (defined inline) ──────────────────────────

class TestGreeter < Restate::Service
  handler :greet
  def greet(ctx, name)
    ctx.run("build-greeting") { "Hello, #{name}!" }.await
  end
end

class TestCounter < Restate::VirtualObject
  handler def add(ctx, addend)
    old_value = ctx.get("count") || 0
    new_value = old_value + addend
    ctx.set("count", new_value)
    {"oldValue" => old_value, "newValue" => new_value}
  end

  shared def get(ctx)
    ctx.get("count") || 0
  end
end

class TestWorker < Restate::Service
  handler def process(ctx, input)
    ctx.run("do-work") { "processed:#{input}" }.await
  end
end

class TestOrchestrator < Restate::Service
  handler def orchestrate(ctx, input)
    result = ctx.service_call(TestWorker, :process, input).await
    "orchestrated:#{result}"
  end
end

# ── Helpers ──────────────────────────────────────────────────

def post_json(base_url, path, body)
  uri = URI("#{base_url}#{path}")
  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request["idempotency-key"] = SecureRandom.uuid
  request.body = JSON.generate(body)
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |http| http.request(request) }
end

# ── Tests ────────────────────────────────────────────────────

RSpec.describe Restate::Testing do
  before(:all) do
    @harness = Restate::Testing::RestateTestHarness.new(
      TestGreeter, TestCounter, TestWorker, TestOrchestrator
    )
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

  it "supports service-to-service calls" do
    response = post_json(@harness.ingress_url, "/TestOrchestrator/orchestrate", "hello")
    expect(response.code).to eq("200")
    expect(JSON.parse(response.body)).to eq("orchestrated:processed:hello")
  end
end
