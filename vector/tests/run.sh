#!/usr/bin/env bash
# Run the Vector unit-test suite for every config in vector/configs/.
#
# For each technology this script:
#   1. substitutes the __INGESTION_URL__ / __SOURCE_TOKEN__ placeholders with
#      dummy values (they only appear in sinks, but the file must stay loadable),
#   2. uses extract-transforms.py to build an environment-independent config
#      (transforms only; sources like kubernetes_logs/journald/host_metrics
#      cannot be built outside their native environment),
#   3. runs `vector test` inside the official Vector docker image.
#
# Requirements: docker, python3. Compatible with macOS bash 3.2 / BSD sed.
#
# Usage: ./run.sh [tech ...]      (default: all technologies)
#   VECTOR_IMAGE=timberio/vector:0.39.0-alpine ./run.sh   # pin the image

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR="$SCRIPT_DIR/../configs"
VECTOR_IMAGE="${VECTOR_IMAGE:-timberio/vector:latest-alpine}"

ALL_TECHS="apache debian docker elasticsearch haproxy kubernetes minio mongodb mysql nginx postgresql rabbitmq traefik"
TECHS="${*:-$ALL_TECHS}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required to run the test suite" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to run extract-transforms.py" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mihari-vector-tests.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

pass_count=0
fail_count=0
failed_techs=""

for tech in $TECHS; do
  config="$CONFIG_DIR/$tech.yaml"
  test_file="$SCRIPT_DIR/$tech.test.yaml"

  if [ ! -f "$config" ]; then
    echo "FAIL $tech (missing config: $config)"
    fail_count=$((fail_count + 1))
    failed_techs="$failed_techs $tech"
    continue
  fi
  if [ ! -f "$test_file" ]; then
    echo "FAIL $tech (missing test file: $test_file)"
    fail_count=$((fail_count + 1))
    failed_techs="$failed_techs $tech"
    continue
  fi

  # 1. substitute placeholders with dummy values
  sed -e 's|__INGESTION_URL__|http://127.0.0.1:9999|g' \
      -e 's|__SOURCE_TOKEN__|dummy-test-token|g' \
      "$config" > "$WORK_DIR/$tech.substituted.yaml"

  # 2. extract transforms into an environment-independent config
  if ! python3 "$SCRIPT_DIR/extract-transforms.py" \
       "$WORK_DIR/$tech.substituted.yaml" > "$WORK_DIR/$tech.config.yaml"; then
    echo "FAIL $tech (extract-transforms.py failed)"
    fail_count=$((fail_count + 1))
    failed_techs="$failed_techs $tech"
    continue
  fi
  cp "$test_file" "$WORK_DIR/$tech.test.yaml"

  # 3. run `vector test` in docker
  if docker run --rm \
       -v "$WORK_DIR":/tests \
       "$VECTOR_IMAGE" \
       test "/tests/$tech.config.yaml" "/tests/$tech.test.yaml" \
       > "$WORK_DIR/$tech.out" 2>&1; then
    echo "PASS $tech"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL $tech"
    sed 's/^/    /' "$WORK_DIR/$tech.out"
    fail_count=$((fail_count + 1))
    failed_techs="$failed_techs $tech"
  fi
done

echo ""
echo "Summary: $pass_count passed, $fail_count failed"
if [ "$fail_count" -gt 0 ]; then
  echo "Failed:$failed_techs"
  exit 1
fi
exit 0
