# frozen_string_literal: true

require "spec_helper"
require "restate/config"
require "restate/client"

# Provide Restate.config / .configure / .client / .resolve_headers since we
# can't load the full module (native extension not compiled in test).
module Restate
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    def client
      cfg = config
      Client.new(ingress_url: cfg.ingress_url, admin_url: cfg.admin_url,
                 ingress_headers: resolve_headers(cfg.ingress_headers),
                 admin_headers: resolve_headers(cfg.admin_headers))
    end

    def resolve_headers(headers)
      headers.respond_to?(:call) ? headers.call : headers
    end

    def reset_config!
      @config = nil
    end
  end
end

RSpec.describe "Callable headers support" do
  before { Restate.reset_config! }
  after  { Restate.reset_config! }

  describe "Restate.resolve_headers" do
    it "returns a Hash as-is" do
      h = { "Foo" => "Bar" }
      expect(Restate.resolve_headers(h)).to equal(h)
    end

    it "calls a lambda and returns the result" do
      callable = -> { { "Dynamic" => "yes" } }
      expect(Restate.resolve_headers(callable)).to eq({ "Dynamic" => "yes" })
    end

    it "calls a Proc and returns the result" do
      callable = proc { { "From" => "proc" } }
      expect(Restate.resolve_headers(callable)).to eq({ "From" => "proc" })
    end

    it "works with any object responding to #call" do
      header_provider = Object.new
      def header_provider.call
        { "Custom" => "provider" }
      end

      expect(Restate.resolve_headers(header_provider)).to eq({ "Custom" => "provider" })
    end
  end

  describe "Restate.client with static headers" do
    it "passes a plain Hash through to the Client" do
      Restate.configure do |c|
        c.ingress_headers = { "Authorization" => "Bearer tok" }
        c.admin_headers   = { "X-Admin" => "yes" }
      end

      client = Restate.client

      # Verify via introspection that the Client received the resolved hashes
      expect(client.instance_variable_get(:@ingress_headers)).to eq({ "Authorization" => "Bearer tok" })
      expect(client.instance_variable_get(:@admin_headers)).to eq({ "X-Admin" => "yes" })
    end
  end

  describe "Restate.client with callable headers" do
    it "invokes a lambda and passes its return value to the Client" do
      call_count = 0
      Restate.configure do |c|
        c.ingress_headers = -> {
          call_count += 1
          { "X-Request-Id" => "req-#{call_count}" }
        }
      end

      client1 = Restate.client
      client2 = Restate.client

      expect(call_count).to eq(2)
      expect(client1.instance_variable_get(:@ingress_headers)).to eq({ "X-Request-Id" => "req-1" })
      expect(client2.instance_variable_get(:@ingress_headers)).to eq({ "X-Request-Id" => "req-2" })
    end

    it "evaluates a Proc fresh on every Restate.client call" do
      counter = 0
      Restate.configure do |c|
        c.admin_headers = proc {
          counter += 1
          { "X-Counter" => counter.to_s }
        }
      end

      clients = 5.times.map { Restate.client }

      expect(counter).to eq(5)
      clients.each_with_index do |client, i|
        expect(client.instance_variable_get(:@admin_headers)).to eq({ "X-Counter" => (i + 1).to_s })
      end
    end

    it "supports callable for admin_headers and static for ingress_headers simultaneously" do
      Restate.configure do |c|
        c.ingress_headers = { "Static" => "header" }
        c.admin_headers   = -> { { "Dynamic" => "admin" } }
      end

      client = Restate.client
      expect(client.instance_variable_get(:@ingress_headers)).to eq({ "Static" => "header" })
      expect(client.instance_variable_get(:@admin_headers)).to eq({ "Dynamic" => "admin" })
    end
  end
end
