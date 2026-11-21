"""Offline tests for integrity and refusal to overwrite an existing checkout."""
import io
import json
from pathlib import Path
import tarfile
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare


class SourcePreparationTests(unittest.TestCase):
    def assert_nested_git_overlay_applies(self, own_checkout):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            decoy = root / "original.txt"
            decoy.write_text("parent remains untouched\n")
            source = root / "nested"
            source.mkdir()
            if own_checkout:
                subprocess.run(["git", "init", "--quiet", str(source)], check=True)
                self.assertEqual(Path(prepare.run("git", "rev-parse", "--show-toplevel", cwd=source)).resolve(),
                                 source.resolve())
            original = source / "original.txt"
            original.write_text("before\n")
            overlay = root / "change.patch"
            overlay.write_text("diff --git a/original.txt b/original.txt\n"
                               "--- a/original.txt\n+++ b/original.txt\n"
                               "@@ -1 +1 @@\n-before\n+after\n")
            lock = {"patches": [{"path": overlay.name, "sha256": prepare.digest(overlay)}], "assets": []}
            with patch.object(prepare, "ROOT", root):
                prepare.apply(source, lock)
            self.assertEqual(original.read_text(), "after\n")
            self.assertEqual(decoy.read_text(), "parent remains untouched\n")
            self.assertEqual(json.loads((source / "CHIICH-SOURCE.json").read_text()), lock)

    def test_archive_output_inside_unrelated_checkout_applies_git_patch(self):
        self.assert_nested_git_overlay_applies(own_checkout=False)

    def test_nested_own_checkout_still_applies_git_patch(self):
        self.assert_nested_git_overlay_applies(own_checkout=True)

    def test_archive_digest_checked_before_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "untrusted.tar.gz"
            archive.write_bytes(b"not an archive")
            with self.assertRaises(ValueError):
                prepare.extract_verified(archive, root, {"archive_sha256": "0" * 64})
            self.assertEqual(list(root.iterdir()), [archive])

    def test_traversal_rejected_even_for_a_digest_verified_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "extract"
            output.mkdir()
            archive = root / "unsafe.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                item = tarfile.TarInfo("../escape.txt")
                item.size = 1
                bundle.addfile(item, io.BytesIO(b"x"))
            lock = {"commit": "fixture", "archive_sha256": prepare.digest(archive)}
            with self.assertRaises(tarfile.FilterError):
                prepare.extract_verified(archive, output, lock)
            self.assertFalse((root / "escape.txt").exists())

    def test_all_patch_inputs_checked_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            original = source / "original.txt"
            original.write_text("before\n")
            good = root / "good.patch"
            good.write_text("--- a/original.txt\n+++ b/original.txt\n@@ -1 +1 @@\n-before\n+after\n")
            bad = root / "bad.patch"
            bad.write_text("tampered")
            lock = {"patches": [{"path": good.name, "sha256": prepare.digest(good)},
                                {"path": bad.name, "sha256": "0" * 64}], "assets": []}
            with patch.object(prepare, "ROOT", root), self.assertRaises(ValueError):
                prepare.apply(source, lock)
            self.assertEqual(original.read_text(), "before\n")

    def test_dependent_overlays_apply_in_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            original = source / "original.txt"
            original.write_text("before\n")
            patches = []
            for index, (before, after) in enumerate([("before", "configured"), ("configured", "native")]):
                overlay = root / f"{index}.patch"
                overlay.write_text(f"--- a/original.txt\n+++ b/original.txt\n@@ -1 +1 @@\n-{before}\n+{after}\n")
                patches.append({"path": overlay.name, "sha256": prepare.digest(overlay)})
            lock = {"patches": patches, "assets": []}
            with patch.object(prepare, "ROOT", root):
                prepare.apply(source, lock)
            self.assertEqual(original.read_text(), "native\n")
            self.assertEqual(json.loads((source / "CHIICH-SOURCE.json").read_text()), lock)

    def test_invalid_later_overlay_leaves_source_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            original = source / "original.txt"
            original.write_text("before\n")
            patches = []
            for index, (before, after) in enumerate([("before", "configured"), ("wrong upstream", "native")]):
                overlay = root / f"{index}.patch"
                overlay.write_text(f"--- a/original.txt\n+++ b/original.txt\n@@ -1 +1 @@\n-{before}\n+{after}\n")
                patches.append({"path": overlay.name, "sha256": prepare.digest(overlay)})
            with patch.object(prepare, "ROOT", root), self.assertRaises(RuntimeError):
                prepare.apply(source, {"patches": patches, "assets": []})
            self.assertEqual(original.read_text(), "before\n")
            self.assertEqual(list(source.iterdir()), [original])

    def test_invalid_asset_leaves_source_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            original = source / "original.txt"
            original.write_text("before\n")
            overlay = root / "good.patch"
            overlay.write_text("--- a/original.txt\n+++ b/original.txt\n@@ -1 +1 @@\n-before\n+after\n")
            asset = root / "logo.svg"
            asset.write_text("tampered")
            lock = {"patches": [{"path": overlay.name, "sha256": prepare.digest(overlay)}],
                    "assets": [{"path": asset.name, "target": "logo.svg", "sha256": "0" * 64}]}
            with patch.object(prepare, "ROOT", root), self.assertRaises(ValueError):
                prepare.apply(source, lock)
            self.assertEqual(original.read_text(), "before\n")
            self.assertEqual(list(source.iterdir()), [original])

    def test_asset_cannot_escape_source_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            asset = root / "logo.svg"
            asset.write_text("logo")
            lock = {"patches": [], "assets": [{"path": asset.name, "target": "../escape.svg",
                                               "sha256": prepare.digest(asset)}]}
            with patch.object(prepare, "ROOT", root), self.assertRaises(ValueError):
                prepare.apply(source, lock)
            self.assertFalse((root / "escape.svg").exists())
            self.assertEqual(list(source.iterdir()), [])

    def test_existing_output_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "upstream.lock.json").write_text(json.dumps({}))
            output = root / "existing"
            output.mkdir()
            marker = output / "keep.txt"
            marker.write_text("keep")
            with patch.object(prepare, "ROOT", root), patch("sys.argv", ["prepare", "--output", str(output)]):
                with self.assertRaises(SystemExit) as error:
                    prepare.main()
            self.assertEqual(error.exception.code, 2)
            self.assertEqual(marker.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
