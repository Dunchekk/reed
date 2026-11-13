#!/usr/bin/env bash
set -euo pipefail
: "${TEST_DATABASE_URL:?Use an explicit disposable test database}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
mkdir -p .local
fixture="$(mktemp "$repo/.local/cloud-e2e.XXXXXX")"
export REED_CLOUD_E2E_CONFIG="$fixture"
node server/test/support/cloud-e2e-server.ts > "$fixture.log" 2>&1 &
fixture_pid=$!
cleanup() {
  kill -INT "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" || true
  rm -f "$fixture"
}
trap cleanup EXIT
for attempt in {1..100}; do
  if [[ -s "$fixture" ]]; then break; fi
  if ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$fixture.log"; exit 1; fi
  sleep 0.1
done
if [[ ! -s "$fixture" ]]; then cat "$fixture.log"; exit 1; fi
swift test --package-path ios/ReedCore --scratch-path .local/swift-build --disable-sandbox --filter twoSwiftReplicas
