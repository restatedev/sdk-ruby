# typed: false
# frozen_string_literal: true

require 'active_record'

module Restate
  # Arel table references for Restate's SQL introspection tables.
  #
  # Restate exposes a DataFusion-powered SQL endpoint at +/query+ on the admin
  # API. These tables let you build queries using Arel's composable, type-safe
  # predicate API — the same one ActiveRecord uses under the hood.
  #
  # @example Query running invocations for a service
  #   i = Restate::Sys::Invocation
  #   query = i.project(i[:id], i[:status], i[:created_at])
  #            .where(i[:target_service_name].eq("MyService"))
  #            .where(i[:status].eq("running"))
  #            .order(i[:created_at].desc)
  #            .take(50)
  #   Restate.query(query)
  #
  # @example Join invocations with their journal input
  #   i = Restate::Sys::Invocation
  #   j = Restate::Sys::Journal
  #   query = i.project(i[:id], i[:target], i[:status], j[:entry_json])
  #            .join(j, Arel::Nodes::OuterJoin)
  #            .on(j[:id].eq(i[:id]).and(j[:index].eq(0)))
  #            .where(i[:target_service_name].eq("CrawlPipeline"))
  #            .order(i[:created_at].desc)
  #            .take(20)
  #   Restate.query(query)
  #
  # @example Query virtual object state
  #   s = Restate::Sys::State
  #   query = s.project(s[:service_name], s[:service_key], s[:key], s[:value_utf8])
  #            .where(s[:service_name].eq("Counter"))
  #   Restate.query(query)
  module Sys
    Invocation       = Arel::Table.new(:sys_invocation)
    Journal          = Arel::Table.new(:sys_journal)
    JournalEvents    = Arel::Table.new(:sys_journal_events)
    Inbox            = Arel::Table.new(:sys_inbox)
    KeyedStatus      = Arel::Table.new(:sys_keyed_service_status)
    Service          = Arel::Table.new(:sys_service)
    Deployment       = Arel::Table.new(:sys_deployment)
    Idempotency      = Arel::Table.new(:sys_idempotency)
    Promise          = Arel::Table.new(:sys_promise)
    State            = Arel::Table.new(:state)
  end

  # Minimal quoting adapter for Arel's ToSql visitor. Emits ANSI SQL
  # (double-quoted identifiers, single-quoted strings) which DataFusion expects.
  # Allows Arel query generation without an ActiveRecord database connection.
  #
  # @!visibility private
  class DataFusionQuoting
    def quote_table_name(name)
      "\"#{name}\""
    end

    def quote_column_name(name)
      "\"#{name}\""
    end

    def quote(value)
      case value
      when String then "'#{value.gsub("'", "''")}'"
      when nil then 'NULL'
      when true then 'TRUE'
      when false then 'FALSE'
      else value.to_s
      end
    end

    def schema_cache
      self
    end

    def columns_hash(_table)
      {}
    end

    def data_source_exists?(_table)
      true
    end
  end

  # Arel visitor that generates ANSI SQL compatible with DataFusion.
  # Uses DataFusionQuoting for identifier/value quoting without requiring
  # a live database connection.
  #
  # @!visibility private
  class DataFusionVisitor < Arel::Visitors::ToSql
    def initialize
      super(DataFusionQuoting.new)
    end
  end

  class << self
    # Convert an Arel AST to a SQL string without requiring an AR connection.
    # Uses a standalone visitor that emits ANSI SQL (DataFusion-compatible).
    #
    # @param arel [Arel::SelectManager] an Arel query
    # @return [String] SQL string
    def arel_to_sql(arel)
      collector = Arel::Collectors::SQLString.new
      DataFusionVisitor.new.accept(arel.ast, collector).value
    end

    # Execute an Arel query or raw SQL string against the Restate admin
    # introspection API. Returns an array of row hashes.
    #
    # @param arel_or_sql [Arel::SelectManager, String] an Arel query or raw SQL
    # @return [Array<Hash>] rows returned by Restate
    #
    # @example With Arel
    #   i = Restate::Sys::Invocation
    #   Restate.query(i.project(Arel.star).take(10))
    #
    # @example With raw SQL
    #   Restate.query("SELECT id, status FROM sys_invocation LIMIT 10")
    def query(arel_or_sql)
      sql = arel_or_sql.respond_to?(:ast) ? arel_to_sql(arel_or_sql) : arel_or_sql.to_s
      client.execute_query(sql)
    end
  end
end
