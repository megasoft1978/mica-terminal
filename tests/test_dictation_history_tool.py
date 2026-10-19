#!/usr/bin/env python3
"""Focused tests for the local dictation history CLI."""

import contextlib
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import dictation_history as history


class DictationHistoryToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "archive"
        self.root.mkdir(mode=0o700)
        self.record_id = str(uuid.uuid4())
        self.record_dir = self.root / self.record_id
        self.record_dir.mkdir(mode=0o700)
        self.metadata_path = self.record_dir / "metadata.json"
        self.record = {
            "schema_version": 1,
            "record_id": self.record_id,
            "created_at": "2026-10-19T10:00:00Z",
            "updated_at": "2026-10-19T10:00:00Z",
            "status": "complete",
            "transcript_hypothesis": "recognized words",
            "human_reference": None,
            "provenance": {"engine": "fixture"},
            "annotations": {},
        }
        self.write_record()
        (self.record_dir / "microphone.caf").write_bytes(b"caf")
        (self.record_dir / "model-input.wav").write_bytes(b"wav")

    def tearDown(self):
        self.temp.cleanup()

    def write_record(self):
        self.metadata_path.write_text(json.dumps(self.record), encoding="utf-8")

    def test_list_and_show_label_transcript_as_hypothesis(self):
        records = history.list_records(self.root)
        self.assertEqual([self.record_id], [item["record_id"] for item in records])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = history.main(["--root", str(self.root), "show", self.record_id])
        self.assertEqual(0, result)
        self.assertIn("Transcript hypothesis: recognized words", output.getvalue())
        self.assertIn("Human reference: (not annotated)", output.getvalue())

    def test_annotate_is_explicit_and_preserves_provenance(self):
        result = history.annotate(self.root, self.record_id, "what I intended")
        self.assertEqual("recognized words", result["transcript_hypothesis"])
        self.assertEqual({"engine": "fixture"}, result["provenance"])
        self.assertEqual("what I intended", result["human_reference"]["text"])
        self.assertEqual("user", result["human_reference"]["source"])
        self.assertIsNotNone(result["human_reference"]["updated_at"])
        self.assertEqual(0o600, stat.S_IMODE(self.metadata_path.stat().st_mode))

    def test_metadata_path_annotation_accepts_only_in_archive_path(self):
        history.annotate(self.root, str(self.metadata_path), "reference")
        outside = Path(self.temp.name) / "other" / "metadata.json"
        with self.assertRaises(history.HistoryError):
            history.annotate(self.root, str(outside), "bad")

    def test_rejects_symlink_record_and_metadata(self):
        external = Path(self.temp.name) / "external"
        external.mkdir()
        external_record = external / self.record_id
        external_record.mkdir()
        (external_record / "metadata.json").write_text(json.dumps(self.record), encoding="utf-8")
        linked = self.root / str(uuid.uuid4())
        linked.symlink_to(external_record)
        with self.assertRaises(history.HistoryError):
            history.list_records(self.root)
        linked.unlink()
        (self.record_dir / "metadata.json").unlink()
        (self.record_dir / "metadata.json").symlink_to(external_record / "metadata.json")
        with self.assertRaises(history.HistoryError):
            history.annotate(self.root, self.record_id, "bad")

    def test_clear_one_record_removes_only_archive_files(self):
        history.clear_record(self.root, self.record_id)
        self.assertFalse(self.record_dir.exists())

    def test_clear_all_removes_all_records(self):
        other_id = str(uuid.uuid4())
        other = self.root / other_id
        other.mkdir()
        (other / "metadata.json").write_text(json.dumps({**self.record, "record_id": other_id}), encoding="utf-8")
        self.assertEqual(2, history.clear_all(self.root))
        self.assertEqual([], history.list_records(self.root))

    def test_clear_all_preserves_disabled_state(self):
        history.set_enabled(self.root, False)
        self.assertEqual(1, history.clear_all(self.root))
        self.assertTrue((self.root / ".disabled").is_file())
        self.assertEqual([], history.list_records(self.root))

    def test_clear_refuses_unexpected_content(self):
        (self.record_dir / "not-owned").write_text("keep")
        with self.assertRaises(history.HistoryError):
            history.clear_record(self.root, self.record_id)
        self.assertTrue((self.record_dir / "not-owned").exists())

    def test_missing_archive_lists_as_empty(self):
        self.assertEqual([], history.list_records(self.root / "not-created"))

    def test_enable_disable_status_and_permissions(self):
        history.set_enabled(self.root, False)
        sentinel = self.root / ".disabled"
        self.assertTrue(sentinel.is_file())
        self.assertEqual(0o600, stat.S_IMODE(sentinel.stat().st_mode))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(0, history.main(["--root", str(self.root), "status"]))
        self.assertIn("Archival: disabled", output.getvalue())
        history.set_enabled(self.root, True)
        self.assertFalse(sentinel.exists())

    def test_status_reports_record_count_and_size(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(0, history.main(["--root", str(self.root), "status"]))
        self.assertIn("Archival: enabled", output.getvalue())
        self.assertIn("Records: 1", output.getvalue())
        self.assertIn("Stored size:", output.getvalue())

    def test_uppercase_native_uuid_record_supports_list_show_annotate_and_clear(self):
        native_id = "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"
        lower_id = native_id.lower()
        self.record_dir.rename(self.root / native_id)
        self.record_id = native_id
        self.record_dir = self.root / native_id
        self.metadata_path = self.record_dir / "metadata.json"
        self.record["record_id"] = native_id
        self.write_record()

        records = history.list_records(self.root)
        self.assertEqual([native_id], [item["record_id"] for item in records])

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(0, history.main(["--root", str(self.root), "show", lower_id]))
        self.assertIn(f"/{native_id}/metadata.json", output.getvalue())

        annotated = history.annotate(self.root, lower_id, "explicit user reference")
        self.assertEqual(native_id, annotated["record_id"])
        self.assertEqual("explicit user reference", annotated["human_reference"]["text"])
        self.assertEqual("user", annotated["human_reference"]["source"])

        history.clear_record(self.root, lower_id)
        self.assertFalse(self.record_dir.exists())


if __name__ == "__main__":
    unittest.main()
