#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Self-contained integration test for the middleware example.
# Starts Falcon + Restate container, invokes the service, verifies output.
#
# Prerequisites: Docker running
#
# Run from the repo root:
#   bundle exec ruby middleware_example/test.rb

require 'restate'
require 'restate/testing'
require 'opentelemetry-sdk'
require 'net/http'
require 'json'
require 'securerandom'

# Load the example code
require_relative 'opentelemetry_middleware'
require_relative 'tenant_middleware'
require_relative 'payment_service'

# Configure OTel (console exporter so we can see spans)
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
      OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
    )
  )
end

# Start the harness with inbound + outbound middleware
harness = Restate::Testing::RestateTestHarness.new(PaymentService, ReceiptService) do |endpoint|
  endpoint.use(OpenTelemetryMiddleware)
  endpoint.use(TenantMiddleware)
  endpoint.use_outbound(TenantOutboundMiddleware)
end

harness.start
puts "Harness started — ingress at #{harness.ingress_url}"

def post(base_url, path, body, headers: {})
  uri = URI("#{base_url}#{path}")
  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req['idempotency-key'] = SecureRandom.uuid
  headers.each { |k, v| req[k] = v }
  req.body = JSON.generate(body)
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |http| http.request(req) }
end

passed = 0
failed = 0

# Test 1: Middleware extracts tenant from header
print 'Test 1: tenant header propagation... '
resp = post(harness.ingress_url, '/PaymentService/charge', '42.00',
            headers: { 'x-tenant-id' => 'acme-corp' })
body = JSON.parse(resp.body)
if resp.code == '200' && body.include?('acme-corp')
  puts "PASS (#{body})"
  passed += 1
else
  puts "FAIL (status=#{resp.code} body=#{body})"
  failed += 1
end

# Test 2: Missing tenant header defaults to 'unknown'
print 'Test 2: missing tenant header... '
resp = post(harness.ingress_url, '/PaymentService/charge', '10.00')
body = JSON.parse(resp.body)
if resp.code == '200' && body.include?('unknown')
  puts "PASS (#{body})"
  passed += 1
else
  puts "FAIL (status=#{resp.code} body=#{body})"
  failed += 1
end

# Test 3: Outbound middleware propagates tenant to ReceiptService
print 'Test 3: outbound tenant propagation to ReceiptService... '
resp = post(harness.ingress_url, '/PaymentService/charge', '99.99',
            headers: { 'x-tenant-id' => 'globex' })
body = JSON.parse(resp.body)
if resp.code == '200' && body.include?('receipt') && body.include?('globex')
  puts "PASS (#{body})"
  passed += 1
else
  puts "FAIL (status=#{resp.code} body=#{body})"
  failed += 1
end

harness.stop
puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
