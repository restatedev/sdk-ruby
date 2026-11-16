# frozen_string_literal: true

require "spec_helper"
require "restate/client"

RSpec.describe Restate::Client do
  let(:client) { described_class.new(ingress_url: "http://localhost:8080/prefix") }
  let(:http) { instance_double(Net::HTTP) }
  let(:response) do
    Net::HTTPOK.new("1.1", "200", "OK").tap do |result|
      allow(result).to receive(:body).and_return('"result"')
    end
  end

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  { "plain-key" => "plain-key", "user#42" => "user%2342",
    "user?42" => "user%3F42", "tenant/42" => "tenant%2F42",
    "user 42" => "user%2042", "user+42" => "user%2B42",
    "user%2F42" => "user%252F42", "café" => "caf%C3%A9" }.each do |key, encoded|
    [:object, :workflow].each do |kind|
      it "encodes #{key.inspect} as one #{kind} key segment" do
        expect(http).to receive(:request) do |request|
          expect(request.path).to eq("/prefix/Counter/#{encoded}/get")
          expect(request.body).to eq("5")
          response
        end
        expect(client.public_send(kind, "Counter", key).get(5)).to eq("result")
      end
    end
  end

  it "keeps stateless service paths unchanged" do
    expect(http).to receive(:request) do |request|
      expect(request.path).to eq("/prefix/Greeter/greet")
      response
    end
    expect(client.service("Greeter").greet).to eq("result")
  end
end
