# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# Build dependencies — must be available in cross-compilation containers
gem 'rake', '~> 13.0'
gem 'rake-compiler', '~> 1.2'
gem 'rb_sys', '~> 0.9'

group :development, :test do
  gem 'base64'
  gem 'dry-struct', require: false
  gem 'falcon', '~> 0.47', require: false
  gem 'rspec', '~> 3.12'
  gem 'rubocop', require: false
  gem 'testcontainers-core', require: false

  # For middleware_example/
  gem 'opentelemetry-api', require: false
  gem 'opentelemetry-sdk', require: false
end
