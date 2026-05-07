# frozen_string_literal: true

#
# Example: Restate Ruby SDK — Introspection with Arel
#
# Query Restate's built-in SQL introspection API using Arel, the same
# relational algebra library that powers ActiveRecord. This gives you
# composable, type-safe queries against system tables like sys_invocation,
# sys_journal, and state — without string interpolation or injection risk.
#
# Prerequisites:
#   - A running Restate server (admin API on localhost:9070)
#   - At least one registered service with some invocations
#
# Usage (standalone, without Rails):
#   ruby examples/introspection.rb
#
# In a Rails app, `Restate::Sys` is loaded automatically via the Railtie.
# Outside Rails, require the introspection module explicitly (requires
# activerecord in your Gemfile).
#
# If you have the full SDK loaded (native extension compiled), you can
# simply `require "restate"`. Otherwise, load just the client layer:

require "restate/config"
require "restate/client"
require "restate/introspection"

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

Restate.config.admin_url = ENV.fetch("RESTATE_ADMIN", "http://localhost:9070")

# Helper to print SQL without requiring an AR connection
def show_sql(query)
  puts "SQL: #{Restate.arel_to_sql(query)}\n\n"
end

# ── Table aliases ──
i = Restate::Sys::Invocation
j = Restate::Sys::Journal
s = Restate::Sys::State

# ── Example 1: List recent invocations ──
puts "=== Recent invocations ==="

query = i.project(i[:id], i[:target_service_name], i[:target_handler_name], i[:status], i[:created_at])
         .order(i[:created_at].desc)
         .take(10)

show_sql(query)
rows = Restate.query(query)
rows.each do |row|
  puts "  #{row['id']} | #{row['target_service_name']}.#{row['target_handler_name']} | #{row['status']}"
end

# ── Example 2: Running invocations for a specific service ──
puts "\n=== Running invocations for 'Greeter' ==="

query = i.project(i[:id], i[:target_handler_name], i[:retry_count], i[:created_at])
         .where(i[:target_service_name].eq("Greeter"))
         .where(i[:status].eq("running"))
         .order(i[:created_at].desc)
         .take(20)

show_sql(query)
rows = Restate.query(query)
rows.each do |row|
  puts "  #{row['id']} | #{row['target_handler_name']} | retries=#{row['retry_count']}"
end

# ── Example 3: Join with journal to get input payloads ──
puts "\n=== Invocations with their input journal entry ==="

query = i.project(i[:id], i[:target], i[:status], j[:entry_json])
         .join(j, Arel::Nodes::OuterJoin)
         .on(j[:id].eq(i[:id]).and(j[:index].eq(0)))
         .where(i[:target_service_name].eq("Greeter"))
         .order(i[:created_at].desc)
         .take(5)

show_sql(query)
rows = Restate.query(query)
rows.each do |row|
  puts "  #{row['id']} | #{row['target']} | #{row['status']}"
  puts "    input: #{row['entry_json']&.slice(0, 80)}..."
end

# ── Example 4: Virtual object state ──
puts "\n=== Virtual object state ==="

query = s.project(s[:service_name], s[:service_key], s[:key], s[:value_utf8])
         .where(s[:service_name].eq("Counter"))
         .take(20)

show_sql(query)
rows = Restate.query(query)
rows.each do |row|
  puts "  #{row['service_name']}/#{row['service_key']} => #{row['key']}=#{row['value_utf8']}"
end

# ── Example 5: Composable query building ──
puts "\n=== Composable queries ==="

# Build a base query and refine it conditionally
service_name = ENV["SERVICE"]
handler_name = ENV["HANDLER"]
status_filter = ENV["STATUS"]

query = i.project(i[:id], i[:target], i[:status], i[:created_at])
query = query.where(i[:target_service_name].eq(service_name)) if service_name
query = query.where(i[:target_handler_name].eq(handler_name)) if handler_name
query = query.where(i[:status].eq(status_filter)) if status_filter
query = query.order(i[:created_at].desc).take(10)

show_sql(query)
rows = Restate.query(query)
puts "  Found #{rows.size} invocations"
rows.each do |row|
  puts "  #{row['id']} | #{row['target']} | #{row['status']} | #{row['created_at']}"
end
