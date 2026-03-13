# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'restate-sdk'
  spec.version = File.read(File.join(__dir__, 'lib', 'restate', 'version.rb'))[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
  spec.authors = ['Restate Developers']
  spec.email = ['code@restate.dev']

  spec.summary = 'Restate SDK for Ruby'
  spec.description = 'Build resilient applications with distributed durable async/await using Restate'
  spec.homepage = 'https://github.com/restatedev/sdk-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir[
    'lib/**/*.rb',
    'ext/**/*.{rs,toml,rb}',
    'Cargo.toml',
    'LICENSE',
    'README.md'
  ]

  spec.require_paths = ['lib']
  spec.extensions = ['ext/restate_internal/extconf.rb']

  spec.add_dependency 'async', '~> 2.0'
  spec.add_dependency 'falcon', '~> 0.47'
  spec.add_dependency 'rack', '>= 2.0'
  spec.add_dependency 'sorbet-runtime'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
