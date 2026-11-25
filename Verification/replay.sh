#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then echo "Usage: replay.sh BOOTED_SIMULATOR_UDID" >&2; exit 2; fi
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pin=$(dirname "$here")
out=$(mktemp -d)
echo "Writing verification outputs to $out"
xcodebuild -project "$pin/PinSavedPlaces.xcodeproj" -scheme PinSavedPlaces -configuration Debug \
  -destination "platform=iOS Simulator,id=$1" -derivedDataPath "$out/build" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build > "$out/build.log"
products="$out/build/Build/Products/Debug-iphonesimulator"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios26.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -I "$products" \
  "$products/PinCore.o" "$pin/Pin/ItinerarySourceRequest.swift" "$pin/Pin/NativItinerary.swift" \
  "$pin/Pin/RailItinerary.swift" "$here/Run.swift" -o "$out/check"
xcrun simctl spawn "$1" "$out/check" < "$here/bank.json" > "$out/results.jsonl"
python3 "$here/grade.py" "$out/results.jsonl"
