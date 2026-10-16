#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
derived_data="${VITALS_DERIVED_DATA:-DerivedData}"
simulator_id=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
for runtime in sorted(runtimes, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in runtimes[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("Install an iOS simulator runtime in Xcode Settings > Components.")
')
# Ad-hoc simulator signing embeds the HealthKit entitlement without an Apple account or provisioning profile.
xcodebuild -project Vitals.xcodeproj -scheme Vitals -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived_data" CODE_SIGN_IDENTITY=- build
xcodebuild -project Vitals.xcodeproj -scheme Vitals -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO build
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project Vitals.xcodeproj -scheme Vitals -parallel-testing-enabled NO -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data" -resultBundlePath "${VITALS_RESULT_BUNDLE:-TestResults.xcresult}" CODE_SIGN_IDENTITY=- test
