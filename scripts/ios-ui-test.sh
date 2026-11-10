#!/usr/bin/env bash
set -euo pipefail
simulator_id="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; devices=json.load(sys.stdin)["devices"]; phones=[d["udid"] for values in devices.values() for d in values if d.get("isAvailable") and "iPhone" in d["name"]]; print(phones[0] if phones else "")')"
if [[ -z "$simulator_id" ]]; then
  echo 'Нет установленного iPhone Simulator runtime. UI-тест требует доступного симулятора.' >&2
  exit 1
fi
xcrun simctl boot "$simulator_id" || true
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project ios/Reed.xcodeproj -scheme Reed -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath .local/DerivedData -resultBundlePath .local/UITests.xcresult CODE_SIGNING_ALLOWED=NO test
