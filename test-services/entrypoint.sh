#!/usr/bin/env sh

# Reset Ruby/Bundler environment to container defaults.
# The sdk-test-suite forwards the host's full environment to the container,
# which can override PATH, GEM_HOME, GEM_PATH etc. with host-specific
# directories that don't exist inside the container.
export PATH="/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GEM_HOME="/usr/local/bundle"
export BUNDLE_APP_CONFIG="/usr/local/bundle"
# GEM_PATH is unset (not pinned) so RubyGems falls back to GEM_HOME plus Ruby's own
# gem dir, which holds bundled gems such as base64 on Ruby >= 3.4.
unset GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN BUNDLE_WITHOUT RUBY_VERSION

PORT=${PORT:-"9080"}

# Unify RESTATE_LOGGING variable (used by e2e-verification-runner)
if [ -n "$RESTATE_LOGGING" ]; then
    export RESTATE_CORE_LOG=$RESTATE_LOGGING
fi

bundle exec falcon serve --bind "http://0.0.0.0:${PORT}" -n 8
