# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "net/http"
require "json"
require "restate/config"
require "restate/client"
require "restate/introspection"

# Provide Restate.config and Restate.client since we can't load the full
# module (native extension not compiled in test).
module Restate
  class << self
    def config
      @config ||= Config.new
    end

    def client
      cfg = config
      Client.new(ingress_url: cfg.ingress_url, admin_url: cfg.admin_url,
                 ingress_headers: cfg.ingress_headers, admin_headers: cfg.admin_headers)
    end
  end
end

RSpec.describe "Restate::Sys introspection" do
  describe "table constants" do
    it "defines Arel tables for all system tables" do
      expect(Restate::Sys::Invocation).to be_a(Arel::Table)
      expect(Restate::Sys::Invocation.name).to eq("sys_invocation")

      expect(Restate::Sys::Journal).to be_a(Arel::Table)
      expect(Restate::Sys::Journal.name).to eq("sys_journal")

      expect(Restate::Sys::State).to be_a(Arel::Table)
      expect(Restate::Sys::State.name).to eq("state")

      expect(Restate::Sys::Service).to be_a(Arel::Table)
      expect(Restate::Sys::Service.name).to eq("sys_service")

      expect(Restate::Sys::Deployment).to be_a(Arel::Table)
      expect(Restate::Sys::Deployment.name).to eq("sys_deployment")

      expect(Restate::Sys::Inbox).to be_a(Arel::Table)
      expect(Restate::Sys::Inbox.name).to eq("sys_inbox")

      expect(Restate::Sys::Promise).to be_a(Arel::Table)
      expect(Restate::Sys::Promise.name).to eq("sys_promise")
    end
  end

  describe "Arel query generation" do
    let(:i) { Restate::Sys::Invocation }
    let(:j) { Restate::Sys::Journal }

    def to_sql(arel)
      Restate.arel_to_sql(arel)
    end

    it "generates a simple SELECT with WHERE and LIMIT" do
      query = i.project(i[:id], i[:status])
               .where(i[:target_service_name].eq("MyService"))
               .take(10)

      sql = to_sql(query)
      expect(sql).to include("sys_invocation")
      expect(sql).to include("target_service_name")
      expect(sql).to include("'MyService'")
      expect(sql).to match(/LIMIT 10|FETCH FIRST 10/)
    end

    it "generates LIKE predicates" do
      query = i.project(i[:id])
               .where(i[:target_service_key].matches("shard_1%"))

      sql = to_sql(query)
      expect(sql).to include("LIKE")
      expect(sql).to include("shard_1%")
    end

    it "generates LEFT OUTER JOIN" do
      query = i.project(i[:id], i[:status], j[:entry_json])
               .join(j, Arel::Nodes::OuterJoin)
               .on(j[:id].eq(i[:id]).and(j[:index].eq(0)))
               .where(i[:target_service_name].eq("CrawlPipeline"))
               .order(i[:created_at].desc)
               .take(20)

      sql = to_sql(query)
      expect(sql).to include("LEFT OUTER JOIN")
      expect(sql).to include("sys_journal")
      expect(sql).to include("'CrawlPipeline'")
      expect(sql).to include("ORDER BY")
      expect(sql).to include("DESC")
    end

    it "supports composable WHERE clauses" do
      query = i.project(i[:id], i[:status])
               .where(i[:target_service_name].eq("MyService"))
               .where(i[:status].eq("running"))
               .where(i[:retry_count].gt(0))

      sql = to_sql(query)
      expect(sql).to include("target_service_name")
      expect(sql).to include("status")
      expect(sql).to include("retry_count")
    end

    it "supports IN predicates" do
      query = i.project(i[:id])
               .where(i[:status].in(%w[running suspended backing-off]))

      sql = to_sql(query)
      expect(sql).to include("running")
      expect(sql).to include("suspended")
      expect(sql).to include("backing-off")
    end

    it "properly escapes single quotes in values" do
      query = i.project(i[:id])
               .where(i[:target_service_key].eq("it's a test"))

      sql = to_sql(query)
      expect(sql).to include("it''s a test")
    end
  end

  describe "Restate.query" do
    it "converts Arel to SQL and calls execute_query on the client" do
      i = Restate::Sys::Invocation
      query = i.project(i[:id]).take(5)
      expected_rows = [{ "id" => "inv_123" }]

      mock_client = instance_double(Restate::Client)
      allow(mock_client).to receive(:execute_query).and_return(expected_rows)
      allow(Restate).to receive(:client).and_return(mock_client)

      result = Restate.query(query)

      expect(result).to eq(expected_rows)
      expect(mock_client).to have_received(:execute_query) do |sql|
        expect(sql).to include("sys_invocation")
        expect(sql).to include("id")
      end
    end

    it "accepts raw SQL strings" do
      raw_sql = "SELECT id FROM sys_invocation LIMIT 5"
      expected_rows = [{ "id" => "inv_456" }]

      mock_client = instance_double(Restate::Client)
      allow(mock_client).to receive(:execute_query).and_return(expected_rows)
      allow(Restate).to receive(:client).and_return(mock_client)

      result = Restate.query(raw_sql)

      expect(result).to eq(expected_rows)
      expect(mock_client).to have_received(:execute_query).with(raw_sql)
    end
  end

  describe "Client#execute_query" do
    it "POSTs SQL to the admin /query endpoint" do
      client = Restate::Client.new(admin_url: "http://localhost:9070")
      sql = "SELECT id FROM sys_invocation LIMIT 1"

      stub_response = instance_double(Net::HTTPSuccess, body: '{"rows":[{"id":"inv_abc"}]}')
      allow(stub_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:start).and_return(stub_response)

      result = client.execute_query(sql)
      expect(result).to eq([{ "id" => "inv_abc" }])
    end

    it "raises on non-success responses" do
      client = Restate::Client.new(admin_url: "http://localhost:9070")

      stub_response = instance_double(Net::HTTPBadRequest, code: "400", body: "bad query")
      allow(stub_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:start).and_return(stub_response)

      expect { client.execute_query("INVALID SQL") }.to raise_error(/Restate query error/)
    end
  end
end
