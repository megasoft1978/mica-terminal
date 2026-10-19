#!/usr/bin/env python3
"""Inspect and manage Mica's local dictation history archive."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid


DEFAULT_ROOT = Path.home() / "Library/Application Support/Mica/DictationHistory"
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class HistoryError(Exception):
    """A malformed record or unsafe archive operation."""


def _root_path(root: Path) -> Path:
    root = root.expanduser().absolute()
    if root.exists() and root.is_symlink():
        raise HistoryError(f"archive root must not be a symlink: {root}")
    return root


def _record_dir(root: Path, identifier: str) -> Path:
    match = UUID_RE.fullmatch(identifier)
    if match:
        identity = uuid.UUID(identifier).hex
        try:
            resolved_root = root.resolve(strict=True)
            matches = [
                entry for entry in root.iterdir()
                if UUID_RE.fullmatch(entry.name) and uuid.UUID(entry.name).hex == identity
            ]
        except (OSError, ValueError) as exc:
            raise HistoryError("archive root is missing or invalid") from exc
        if len(matches) > 1:
            raise HistoryError("multiple archive directories have the same UUID")
        directory = matches[0] if matches else root / identifier
    else:
        supplied = Path(identifier).expanduser()
        if supplied.name != "metadata.json" or not supplied.is_absolute():
            raise HistoryError("record must be a UUID or an absolute <UUID>/metadata.json path")
        directory = supplied.parent
    try:
        resolved_root = root.resolve(strict=True)
        resolved_dir = directory.resolve(strict=True)
        resolved_dir.relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        raise HistoryError("record path is missing or outside the archive") from exc
    if directory.is_symlink() or not resolved_dir.is_dir():
        raise HistoryError("record directory must be a real directory inside the archive")
    if not UUID_RE.fullmatch(resolved_dir.name):
        raise HistoryError("record directory name is not a UUID")
    metadata = resolved_dir / "metadata.json"
    if metadata.is_symlink() or not metadata.is_file():
        raise HistoryError("record metadata is missing or unsafe")
    return resolved_dir


def _read_record(directory: Path) -> dict:
    try:
        with (directory / "metadata.json").open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise HistoryError(f"cannot read {directory.name}: {exc}") from exc
    if not isinstance(value, dict):
        raise HistoryError(f"invalid metadata for {directory.name}")
    try:
        metadata_identity = uuid.UUID(value.get("record_id", "")).hex
        directory_identity = uuid.UUID(directory.name).hex
    except (AttributeError, TypeError, ValueError) as exc:
        raise HistoryError(f"invalid metadata for {directory.name}") from exc
    if metadata_identity != directory_identity:
        raise HistoryError(f"invalid metadata for {directory.name}")
    return value


def list_records(root: Path) -> list[dict]:
    if not root.exists():
        return []
    if root.is_symlink() or not root.is_dir():
        raise HistoryError("archive root is not a real directory")
    records = []
    for directory in sorted(root.iterdir()):
        if not UUID_RE.fullmatch(directory.name):
            continue
        if directory.is_symlink() or not directory.is_dir():
            raise HistoryError(f"unsafe record entry: {directory.name}")
        record = _read_record(_record_dir(root, directory.name))
        records.append(record)
    return records


def _atomic_write(metadata_path: Path, payload: dict) -> None:
    parent = metadata_path.parent
    if metadata_path.is_symlink():
        raise HistoryError("metadata file must not be a symlink")
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".metadata-", dir=parent)
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, metadata_path)
        temporary = None
        os.chmod(metadata_path, stat.S_IRUSR | stat.S_IWUSR)
        dir_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as exc:
        raise HistoryError(f"cannot update metadata: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def annotate(root: Path, identifier: str, text: str) -> dict:
    directory = _record_dir(root, identifier)
    record = _read_record(directory)
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    record["human_reference"] = {"text": text, "source": "user", "updated_at": now}
    record["updated_at"] = now
    _atomic_write(directory / "metadata.json", record)
    return record


def clear_record(root: Path, identifier: str) -> None:
    directory = _record_dir(root, identifier)
    # The archive store uses only fixed filenames. Refuse unexpected entries so
    # this command cannot recursively remove unrelated content.
    allowed = {"metadata.json", "microphone.caf", "model-input.wav"}
    for child in directory.iterdir():
        if child.name not in allowed or child.is_symlink() or not child.is_file():
            raise HistoryError(f"refusing to clear record with unexpected entry: {child.name}")
    for child in directory.iterdir():
        child.unlink()
    directory.rmdir()


def clear_all(root: Path) -> int:
    records = list_records(root)
    for record in records:
        clear_record(root, record["record_id"])
    return len(records)


def set_enabled(root: Path, enabled: bool) -> None:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink() or not root.is_dir():
        raise HistoryError("archive root is not a real directory")
    sentinel = root / ".disabled"
    if enabled:
        if sentinel.is_symlink():
            raise HistoryError("disable sentinel must not be a symlink")
        try:
            sentinel.unlink(missing_ok=True)
        except OSError as exc:
            raise HistoryError(f"cannot enable archival: {exc}") from exc
        return
    if sentinel.exists() and (sentinel.is_symlink() or not sentinel.is_file()):
        raise HistoryError("disable sentinel is unsafe")
    if sentinel.is_symlink():
        raise HistoryError("disable sentinel must not be a symlink")
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".disabled-", dir=root)
        os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("Disabled by user\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, sentinel)
        temporary = None
    except OSError as exc:
        raise HistoryError(f"cannot disable archival: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def archive_size(root: Path) -> int:
    total = 0
    for record in list_records(root):
        directory = root / record["record_id"]
        for name in ("metadata.json", "microphone.caf", "model-input.wav"):
            path = directory / name
            if path.exists() and not path.is_symlink():
                total += path.stat().st_size
    return total


def _format_record(record: dict) -> str:
    reference = record.get("human_reference")
    return "\n".join((
        f"Record: {record.get('record_id', '(unknown)')}",
        f"Status: {record.get('status', '(unknown)')}",
        f"Created: {record.get('created_at', '(unknown)')}",
        f"Transcript hypothesis: {record.get('transcript_hypothesis') or '(none)' }",
        f"Human reference: {reference.get('text') if isinstance(reference, dict) else '(not annotated)'}",
        f"Metadata: {record.get('_metadata_path', '(see archive)')}",
    ))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT,
                        help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="list archived dictations")
    commands.add_parser("status", help="show archival state and current size")
    commands.add_parser("enable", help="resume local recording archival")
    commands.add_parser("disable", help="stop archiving new recordings")
    show = commands.add_parser("show", help="inspect a record by UUID or metadata path")
    show.add_argument("record")
    note = commands.add_parser("annotate", help="attach explicit user reference text")
    note.add_argument("record")
    note.add_argument("--text", required=True, help="exact text you intended to dictate")
    clear = commands.add_parser("clear", help="delete one record or the complete archive")
    clear.add_argument("record", nargs="?")
    clear.add_argument("--all", action="store_true", help="clear every archived record")
    args = parser.parse_args(argv)
    root = _root_path(args.root)
    try:
        if args.command == "list":
            records = list_records(root)
            for record in records:
                print(f"{record.get('record_id')}\t{record.get('status')}\t{record.get('transcript_hypothesis') or '(no transcript)'}")
            print(f"{len(records)} record(s)")
        elif args.command == "status":
            disabled = (root / ".disabled").exists()
            records = list_records(root)
            print(f"Archival: {'disabled' if disabled else 'enabled'}")
            print(f"Records: {len(records)}")
            print(f"Stored size: {archive_size(root)} bytes")
        elif args.command == "disable":
            set_enabled(root, False)
            print("Archival disabled; dictation continues without being saved")
        elif args.command == "enable":
            set_enabled(root, True)
            print("Archival enabled")
        elif args.command == "show":
            directory = _record_dir(root, args.record)
            record = _read_record(directory)
            record["_metadata_path"] = str(directory / "metadata.json")
            print(_format_record(record))
        elif args.command == "annotate":
            if not args.text.strip():
                raise HistoryError("reference text must not be empty")
            record = annotate(root, args.record, args.text)
            print(f"Saved user reference for {record['record_id']}")
        elif args.command == "clear":
            if args.all and args.record:
                raise HistoryError("choose either a record or --all")
            if args.all:
                print(f"Cleared {clear_all(root)} record(s)")
            elif args.record:
                record_id = _read_record(_record_dir(root, args.record))["record_id"]
                clear_record(root, record_id)
                print(f"Cleared {record_id}")
            else:
                raise HistoryError("specify a UUID/metadata path or --all")
        return 0
    except HistoryError as exc:
        print(f"dictation-history: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
