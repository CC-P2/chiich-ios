#!/usr/bin/env python3
"""Prepare/export real native preview captures in a disposable CI checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

HARNESS_SHA256 = "41f40c24aa61a932e8a8b70607edee8d41522c9b57cf26f8250d215041b3a9e6"
EXPECTED = {"chiichNativeExperience": 8, "chiichMessageDisclosure": 6, "chiichLogin": 8,
            "chiichHomeControls": 4, "cHIICHIdentitySettings": 16,
            "cHIICHPasswordScreen": 8, "chiichReceiverAILanguages": 4}


def prepare(source):
    harness = source / "PreviewTests/Sources/PreviewTests.swift"
    data = harness.read_bytes()
    if hashlib.sha256(data).hexdigest() != HARNESS_SHA256:
        raise ValueError("Native preview harness differs from the reviewed upstream pin")
    text = data.decode()
    old = "                Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation)"
    new = '''                // Capture new CHIICH previews for visual review. This is recording,
                // not a comparison against an approved visual baseline. Keep all
                // rendering errors and unexpected failures as test failures.
                let isNewCapture = ProcessInfo.processInfo.environment["CHIICH_RECORD_PREVIEWS"] == "1"
                    && failure.hasPrefix("No reference was found on disk. Automatically recorded snapshot:")
                if !isNewCapture {
                    Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation)
                }'''
    if text.count(old) != 1:
        raise ValueError("Native preview recording anchor must be unique")
    traits_old = "            let traits = UITraitCollection(displayScale: 2.0)"
    traits_new = '''            // Match the app window's UIKit style as well as SwiftUI's environment.
            // Otherwise navigation controls can retain light-mode tint in graphite captures.
            let graphiteNames: Set<String> = ["Loaded chats graphite", "Conversation graphite",
                                              "Graphite messages", "Settings graphite",
                                              "Graphite profile link", "Graphite first username", "Graphite password",
                                              "Graphite translation languages"]
            let style: UIUserInterfaceStyle = graphiteNames.contains(preview.displayName ?? "") ? .dark : .light
            let traits = UITraitCollection(traitsFrom: [UITraitCollection(displayScale: 2.0),
                                                        UITraitCollection(userInterfaceStyle: style)])'''
    if text.count(traits_old) != 1:
        raise ValueError("Native preview trait anchor must be unique")
    plan_path = source / "PreviewTests/SupportingFiles/PreviewTests.xctestplan"
    plan = json.loads(plan_path.read_text())
    language = next(item for item in plan["configurations"] if item["name"] == "English")
    language["name"] = "Russian"
    language["options"].update({"language": "ru", "region": "RU"})
    plan["configurations"] = [language]
    plan["defaultOptions"]["environmentVariableEntries"].append({"key": "CHIICH_RECORD_PREVIEWS", "value": "1"})
    harness.write_text(text.replace(old, new).replace(traits_old, traits_new))
    plan_path.write_text(json.dumps(plan, indent=2) + "\n")
    print(f"Prepared {len(EXPECTED)} focused native preview suites for Russian image capture.")


def export(source, output):
    if output.exists():
        raise ValueError("Preview output already exists; never overwrite evidence")
    selected = []
    counts = dict.fromkeys(EXPECTED, 0)
    for path in (source / "PreviewTests/Sources/__Snapshots__/PreviewTests").glob("*.png"):
        suite = path.name.split(".", 1)[0]
        if suite not in EXPECTED:
            continue
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 100:
            raise ValueError("Preview is not a rendered PNG: " + path.name)
        width, height = struct.unpack(">II", data[16:24])
        if width < 100 or height < 100:
            raise ValueError("Preview is empty or unexpectedly small: " + path.name)
        counts[suite] += 1
        selected.append((path, {"file": path.name, "width": width, "height": height,
                                "sha256": hashlib.sha256(data).hexdigest()}))
    if counts != EXPECTED:
        raise ValueError(f"Native preview captures incomplete: {counts}; expected {EXPECTED}")
    output.mkdir(parents=True)
    for path, _ in selected:
        shutil.copyfile(path, output / path.name)
    manifest = {"kind": "native SwiftUI preview recording; visual review required",
                "locale": "ru-RU", "screenshots": sorted((item for _, item in selected), key=lambda item: item["file"])}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Exported {len(selected)} real native preview images for inspection.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "export"])
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.mode == "prepare":
        prepare(args.source.resolve())
    else:
        if args.output is None:
            parser.error("export requires --output")
        export(args.source.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
