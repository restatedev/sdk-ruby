#!/usr/bin/env bash
set -euo pipefail

# Post-release smoke test for the Restate Ruby SDK.
#
# Copies the template/ to a temp directory, installs the gem from RubyGems,
# starts a real Restate container, invokes the service, and verifies the response.
#
# Prerequisites: Docker running, Ruby >= 3.1
#
# Usage:
#   ./etc/smoke-test.sh                    # test latest released version
#   ./etc/smoke-test.sh 0.7.0             # test a specific version
#   ./etc/smoke-test.sh local             # test the locally-built gem

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
WORK_DIR=$(mktemp -d)

cleanup() {
  echo "==> Cleaning up ${WORK_DIR}"
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "==> Smoke test directory: ${WORK_DIR}"

# 1. Copy template
cp -r "${REPO_ROOT}/template/"* "${WORK_DIR}/"

# 2. Adjust Gemfile based on version argument
if [ "${VERSION}" = "local" ]; then
  echo "==> Testing LOCAL gem build"
  cat > "${WORK_DIR}/Gemfile" <<GEMFILE
source 'https://rubygems.org'

gem 'falcon', '~> 0.47'
gem 'restate-sdk', path: '${REPO_ROOT}'
gem 'testcontainers-core', require: false
GEMFILE
elif [ -n "${VERSION}" ]; then
  echo "==> Testing gem version ${VERSION}"
  cat > "${WORK_DIR}/Gemfile" <<GEMFILE
source 'https://rubygems.org'

gem 'falcon', '~> 0.47'
gem 'restate-sdk', '${VERSION}'
gem 'testcontainers-core', require: false
GEMFILE
else
  echo "==> Testing latest released gem"
  cat > "${WORK_DIR}/Gemfile" <<GEMFILE
source 'https://rubygems.org'

gem 'falcon', '~> 0.47'
gem 'restate-sdk'
gem 'testcontainers-core', require: false
GEMFILE
fi

# 3. Write the smoke test
cat > "${WORK_DIR}/smoke_test.rb" <<'RUBY'
#!/usr/bin/env ruby
# frozen_string_literal: true

require 'restate'
require 'restate/testing'
require 'net/http'
require 'json'
require 'securerandom'

# Load the template service
require_relative 'greeter'

passed = 0
failed = 0

def post(base_url, path, body)
  uri = URI("#{base_url}#{path}")
  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req['idempotency-key'] = SecureRandom.uuid
  req.body = JSON.generate(body)
  Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |http| http.request(req) }
end

harness = Restate::Testing::RestateTestHarness.new(Greeter)
harness.start
puts "Harness started — ingress at #{harness.ingress_url}"

# Test 1: Invoke the greeter
print 'Test 1: Greeter returns greeting... '
resp = post(harness.ingress_url, '/Greeter/greet', 'SmokeTest')
body = JSON.parse(resp.body)
if resp.code == '200' && body == 'Hello, SmokeTest!'
  puts "PASS (#{body})"
  passed += 1
else
  puts "FAIL (status=#{resp.code} body=#{body})"
  failed += 1
end

# Test 2: Invoke with a different name (verifies durable execution)
print 'Test 2: Greeter with different input... '
resp = post(harness.ingress_url, '/Greeter/greet', 'Ruby')
body = JSON.parse(resp.body)
if resp.code == '200' && body == 'Hello, Ruby!'
  puts "PASS (#{body})"
  passed += 1
else
  puts "FAIL (status=#{resp.code} body=#{body})"
  failed += 1
end

# Test 3: Verify Restate.client works
print 'Test 3: Restate::Client invocation... '
begin
  client = Restate::Client.new(ingress_url: harness.ingress_url)
  result = client.service('Greeter').greet('Client')
  if result == 'Hello, Client!'
    puts "PASS (#{result})"
    passed += 1
  else
    puts "FAIL (result=#{result})"
    failed += 1
  end
rescue StandardError => e
  puts "FAIL (#{e})"
  failed += 1
end

harness.stop
puts "\n#{passed} passed, #{failed} failed"
exit(failed.zero? ? 0 : 1)
RUBY

# 4. Install dependencies
echo "==> Installing dependencies..."
cd "${WORK_DIR}"
bundle install --quiet

# 5. Run the smoke test
echo "==> Running smoke test..."
bundle exec ruby smoke_test.rb

echo "==> Smoke test passed!"
