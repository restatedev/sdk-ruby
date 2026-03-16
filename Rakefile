# frozen_string_literal: true

require 'rake/extensiontask'
require 'rspec/core/rake_task'

CROSS_PLATFORMS = %w[
  x86_64-linux
  aarch64-linux
  x86_64-linux-musl
  aarch64-linux-musl
  x86_64-darwin
  arm64-darwin
].freeze

Rake::ExtensionTask.new('restate_internal') do |ext|
  ext.lib_dir = 'lib/restate'
  ext.source_pattern = '*.{rs,toml}'
  ext.cross_compile = true
  ext.cross_platform = CROSS_PLATFORMS
end

RSpec::Core::RakeTask.new(:spec)

task default: %i[compile spec]
