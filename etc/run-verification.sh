#!/usr/bin/env bash
set -euo pipefail

# Run the e2e verification tests against the Ruby SDK interpreter services.
#
# Prerequisites:
#   - Docker running
#
# Usage:
#   ./etc/run-verification.sh              # build image + run verification
#   ./etc/run-verification.sh --skip-build # run verification only (reuse existing image)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_IMAGE="restatedev/test-services-ruby"
DRIVER_IMAGE="${DRIVER_IMAGE:-ghcr.io/restatedev/e2e-verification-runner:main}"
RESTATE_IMAGE="${RESTATE_CONTAINER_IMAGE:-ghcr.io/restatedev/restate:main}"

export SERVICES_CONTAINER_IMAGE="${SERVICE_IMAGE}"
export RESTATE_CONTAINER_IMAGE="${RESTATE_IMAGE}"
export SEED=$(date +%s)

SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
  esac
done

# 1. Build the test-services Docker image
if [ "$SKIP_BUILD" = false ]; then
  echo "==> Building test-services Docker image..."
  docker build -f "${REPO_ROOT}/test-services/Dockerfile" -t "${SERVICE_IMAGE}" "${REPO_ROOT}"
fi

# 2. Pull driver and restate images
echo "==> Pulling driver image: ${DRIVER_IMAGE}"
docker pull "${DRIVER_IMAGE}"
echo "==> Pulling Restate image: ${RESTATE_IMAGE}"
docker pull "${RESTATE_IMAGE}"

# 3. Template the config files
function template_json() {
  local tmpfile=$(mktemp)
  echo "local template=\$(cat <<-EOF" >> $tmpfile
  cat $1 >> $tmpfile
  echo "" >> $tmpfile
  echo "EOF" >> $tmpfile
  echo ")" >> $tmpfile
  source $tmpfile
  rm $tmpfile
  echo $template
}

ENV_FILE="${REPO_ROOT}/etc/verification/env.json"
PARAMS_FILE="${REPO_ROOT}/etc/verification/params.json"

export INTERPRETER_DRIVER_CONF=$(template_json ${PARAMS_FILE})
export UNIVERSE_ENV_JSON=$(template_json ${ENV_FILE})
export SERVICES=InterpreterDriverJob
export NODE_ENV=production
export NODE_OPTIONS="--max-old-space-size=4096"
export AWS_LAMBDA_FUNCTION_NAME=1
export DEBUG=testcontainers:containers

# 4. Run the verification driver
echo "==> Running verification tests..."
echo "    Keys: 1000, Tests: 1000, MaxProgramSize: 10"

docker run \
  --net host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --env SERVICES \
  --env NODE_ENV \
  --env NODE_OPTIONS \
  --env AWS_LAMBDA_FUNCTION_NAME \
  --env DEBUG \
  --env INTERPRETER_DRIVER_CONF \
  --env UNIVERSE_ENV_JSON \
  ${DRIVER_IMAGE}

echo "==> Verification complete."
