#!/usr/bin/env python3
"""Prepare the pinned CHIICH iOS source; no credentials, signing or deployment."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_file(path, expected):
    if digest(path) != expected:
        raise ValueError(f"Integrity check failed: {path.name}")


def run(*args, cwd):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Source preparation command failed: {result.stderr.strip()}")
    return result.stdout.strip()


def apply(source, lock):
    # Verify all inputs first. Later overlays may depend on earlier overlays,
    # so validate the whole sequence on a disposable copy before changing source.
    for item in lock["patches"]:
        verify_file(ROOT / item["path"], item["sha256"])
    for item in lock["assets"]:
        verify_file(ROOT / item["path"], item["sha256"])
        target = source / item["target"]
        if not target.resolve().is_relative_to(source.resolve()):
            raise ValueError("Asset target must stay within the source tree")
    with tempfile.TemporaryDirectory(prefix="chiich-ios-preflight-") as directory:
        staged = Path(directory) / "source"
        # Preserve symlinks: git apply rejects writes through them. A full copy
        # also supports binary patches, renames and patches of newly added files.
        shutil.copytree(source, staged, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        for item in lock["patches"]:
            run("git", "apply", str(ROOT / item["path"]), cwd=staged)
        copy_assets(staged, lock["assets"])
    for item in lock["patches"]:
        run("git", "apply", str(ROOT / item["path"]), cwd=source)
    copy_assets(source, lock["assets"])
    (source / "CHIICH-SOURCE.json").write_text(json.dumps(lock, indent=2) + "\n")


def copy_assets(source, assets):
    for item in assets:
        target = source / item["target"]
        if not target.resolve().is_relative_to(source.resolve()):
            raise ValueError("Asset target must stay within the source tree")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / item["path"], target)


def extract_verified(archive, parent, lock):
    verify_file(archive, lock["archive_sha256"])
    with tarfile.open(archive) as bundle:
        # Python's data filter rejects absolute paths, traversal and escaping links.
        bundle.extractall(parent, filter="data")
    source = parent / f"element-x-ios-{lock['commit']}"
    if not (source / "project.yml").is_file():
        raise ValueError("Pinned archive did not contain the expected project")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--output", type=Path, help="New output directory (never overwritten)")
    group.add_argument("--source", type=Path, help="Clean Git checkout at the exact pinned commit")
    parser.add_argument("--archive", type=Path, help="Use a previously downloaded archive, offline")
    args = parser.parse_args()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    if args.source:
        if args.archive:
            parser.error("--archive belongs to --output")
        source = args.source.resolve()
        if run("git", "rev-parse", "HEAD", cwd=source) != lock["commit"]:
            parser.error("Source must be at the exact pinned commit")
        if run("git", "status", "--porcelain", cwd=source):
            parser.error("Source must be clean; existing changes are never overwritten")
        apply(source, lock)
    else:
        output = args.output.resolve()
        if output.exists():
            parser.error("Output exists; choose a new directory")
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="chiich-ios-", dir=output.parent) as temp:
            temp = Path(temp)
            archive = args.archive.resolve() if args.archive else temp / "upstream.tar.gz"
            if not args.archive:
                request = urllib.request.Request(lock["archive_url"], headers={"User-Agent": "CHIICH-source-preparation"})
                with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as target:
                    shutil.copyfileobj(response, target)
            source = extract_verified(archive, temp, lock)
            apply(source, lock)
            source.rename(output)
        source = output
    print(f"Prepared CHIICH iOS source: {source}")
    print("Source preparation only. An Xcode build and own Apple signing are still required.")


if __name__ == "__main__":
    main()
