#!/usr/bin/env bash
# Capture native screens with explicit curated synthetic UI-test data.
# This runs only the unsigned iOS Simulator; it never signs/uploads a build.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 GENERATED_NATIVE_SOURCE OUTPUT_DIRECTORY" >&2
  exit 2
fi

chiich_source="$(cd "$1" && pwd)"
chiich_output="$2"
[[ "$chiich_output" = /* ]] || chiich_output="$PWD/$chiich_output"
if [[ -e "$chiich_output" ]]; then
  echo "Refusing to overwrite screenshot evidence: $chiich_output" >&2
  exit 2
fi
test -f "$chiich_source/ElementX.xcodeproj/project.pbxproj"
test -f "$chiich_source/UITests/Sources/ChiichHomeControlsTests.swift"
mkdir -p "$chiich_output"

# Reuse the exact generated source, Russian UI-test plan and DerivedData from
# the simulator workflow. Keep its iPhone 17 / iPad (A16) regression checks.
# Capture curated data separately at the required Dynamic Island medium / iPad13
# sizes and an additional large iPhone size. Regression attachments are not reused.
chiich_failed=0
for chiich_capture in 'iPhone17|iPhone 17' 'iPhone18ProMax|iPhone 18 Pro Max' 'iPad13|iPad Pro 13-inch (M5)'; do
  chiich_key="${chiich_capture%%|*}"
  chiich_device="${chiich_capture#*|}"
  chiich_result="$chiich_output/$chiich_key.xcresult"

  if ! (
    cd "$chiich_source"
    xcodebuild -quiet test \
      -project ElementX.xcodeproj \
      -scheme UITests \
      -configuration Debug \
      -destination "platform=iOS Simulator,name=$chiich_device,OS=27.0,arch=arm64" \
      -derivedDataPath ../DerivedData \
      -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
      -resultBundlePath "$chiich_result" \
      -only-testing:UITests/ChiichHomeControlsTests/testStoreLightScreenshots \
      -only-testing:UITests/ChiichHomeControlsTests/testStoreGraphiteScreenshots \
      -parallel-testing-enabled NO \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
  ); then
    chiich_failed=1
  fi

  if [[ -d "$chiich_result" ]]; then
    xcrun xcresulttool get test-results summary --path "$chiich_result" \
      > "$chiich_output/$chiich_key-summary.json" || chiich_failed=1
    xcrun xcresulttool export attachments --path "$chiich_result" \
      --output-path "$chiich_output/$chiich_key" || chiich_failed=1
  else
    chiich_failed=1
  fi
done

python3 - "$chiich_output" <<'PY'
import hashlib
import json
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
expected = {
    "iPhone17": {(1206, 2622), (2622, 1206)},
    "iPhone18ProMax": {(1320, 2868), (2868, 1320)},
    "iPad13": {(2064, 2752), (2752, 2064)},
}
manifest = {
    "kind": "unaltered native full-app simulator UI-test attachments",
    "locale": "ru-RU",
    "source": "ChiichHomeControlsTests explicit CHIICH_STORE_CAPTURE curated synthetic fixture",
    "unsigned_simulator_only": True,
    "full_app_capture": True,
    "fixture_data_is_synthetic": True,
    "expected_screens": ["chats", "settings", "search"],
    "expected_appearances": ["light", "graphite"],
    "visual_review_required": True,
    "apple_upload_performed": False,
    "screenshots": [],
}
errors = []
for device, dimensions in expected.items():
    summary_path = root / f"{device}-summary.json"
    if not summary_path.exists():
        errors.append(f"Missing test summary for {device}")
        continue
    summary = json.loads(summary_path.read_text())
    if (summary.get("totalTestCount"), summary.get("passedTests"),
            summary.get("failedTests", 0), summary.get("skippedTests", 0)) != (2, 2, 0, 0):
        errors.append(f"Expected two successful capture tests for {device}: {summary}")
    matching = 0
    for path in sorted((root / device).rglob("*.png")):
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 33:
            errors.append(f"Invalid PNG: {path.relative_to(root)}")
            continue
        width, height, depth, color_type = struct.unpack(">IIBB", data[16:26])
        has_alpha = color_type in (4, 6)
        # PNG palette/grayscale transparency may also use a tRNS chunk.
        offset = 8
        while offset + 12 <= len(data):
            length = int.from_bytes(data[offset:offset + 4], "big")
            chunk = data[offset + 4:offset + 8]
            if offset + length + 12 > len(data):
                errors.append(f"Truncated PNG: {path.relative_to(root)}")
                break
            has_alpha = has_alpha or chunk == b"tRNS"
            offset += length + 12
            if chunk == b"IEND":
                break
        correct_size = (width, height) in dimensions
        matching += int(correct_size)
        manifest["screenshots"].append({
            "file": str(path.relative_to(root)), "device": device,
            "width": width, "height": height, "bit_depth": depth,
            "sha256": hashlib.sha256(data).hexdigest(),
            "required_device_dimensions_match": correct_size,
            "has_alpha_or_transparency": bool(has_alpha),
        })
    if matching < 6:
        errors.append(f"Expected at least six native captures at {device} dimensions; got {matching}")

manifest["validation_errors"] = errors
(root / "capture-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Recorded {len(manifest['screenshots'])} unaltered PNG attachments. Visual and alpha review remain required.")
PY

exit "$chiich_failed"
