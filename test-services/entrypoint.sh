#!/usr/bin/env sh

PORT=${PORT:-"9080"}

# Unify RESTATE_LOGGING variable (used by e2e-verification-runner)
if [ -n "$RESTATE_LOGGING" ]; then
    export RESTATE_CORE_LOG=$RESTATE_LOGGING
fi

bundle exec falcon serve --bind "http://0.0.0.0:${PORT}" -n 8
