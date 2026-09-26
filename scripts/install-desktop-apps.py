#!/usr/bin/env python3
"""Install one Mica app bundle per existing Zellij project launcher on macOS."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path


HOME = Path.home()
DEFAULT_LAYOUTS = HOME / ".config/mica/layouts"
DEFAULT_DESKTOP = HOME / "Desktop"
DEFAULT_BASE_APP = Path(__file__).resolve().parents[1] / "build/Mica.app"
DEFAULT_MANIFEST = HOME / ".config/mica/desktop-apps.json"
DEFAULT_BACKUPS = HOME / ".local/share/mica/launcher-backups"


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def write_json_atomic(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def discover_launchers(launcher_dir: Path, layout_dir: Path) -> list[dict]:
    projects = []
    for app in sorted(launcher_dir.glob("*.app")):
        plist_path = app / "Contents/Info.plist"
        script_path = app / "Contents/Resources/Scripts/main.scpt"
        if not plist_path.is_file() or not script_path.is_file():
            continue
        try:
            source = subprocess.run(
                ["osadecompile", str(script_path)], check=True, capture_output=True, text=True
            ).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            raise RuntimeError(f"cannot inspect launcher AppleScript {script_path}: {exc}") from exc
        match = re.search(r"(?P<path>/[^\"'\n]*?/launch-[A-Za-z0-9_-]+\.sh)", source)
        if not match:
            continue
        launch_script = Path(match.group("path"))
        if not launch_script.is_file():
            raise RuntimeError(f"launcher {app.name} references missing script {launch_script}")
        script = launch_script.read_text(encoding="utf-8")
        layout_match = re.search(r"^\s*LAYOUT_FILE\s*=\s*[\"']([^\"']+)[\"']", script, re.MULTILINE)
        if not layout_match:
            continue
        layout_name = layout_match.group(1)
        layout_path = layout_dir / f"{layout_name}.mica"
        if not layout_path.is_file():
            raise RuntimeError(f"launcher {app.name} needs missing Mica layout {layout_path}")
        info = read_plist(plist_path)
        projects.append({
            "app_name": app.name,
            "display_name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or app.stem,
            "bundle_identifier": info.get("CFBundleIdentifier"),
            "layout_name": layout_name,
            "launch_script": str(launch_script.resolve()),
        })
    if not projects:
        raise RuntimeError(
            f"no Desktop AppleScript launchers with matching .mica layouts were found in {launcher_dir}"
        )
    return projects


def load_projects(manifest: Path, launcher_dir: Path, layout_dir: Path, output_dir: Path) -> list[dict]:
    if manifest.is_file():
        records = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(records, list) or not records:
            raise RuntimeError(f"invalid or empty desktop app manifest: {manifest}")
        projects = records
    else:
        projects = discover_launchers(launcher_dir, layout_dir)
    for project in projects:
        app_name = project.get("app_name")
        layout_name = project.get("layout_name")
        if not isinstance(app_name, str) or not app_name.endswith(".app"):
            raise RuntimeError(f"invalid app name in desktop manifest: {app_name!r}")
        if not isinstance(layout_name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", layout_name):
            raise RuntimeError(f"invalid layout name for {app_name}: {layout_name!r}")
        layout_path = layout_dir / f"{layout_name}.mica"
        if not layout_path.is_file():
            raise RuntimeError(f"missing Mica layout for {app_name}: {layout_path}")
        project["layout_path"] = str(layout_path.resolve())
        project["app_path"] = str((output_dir / app_name).resolve())
        project.setdefault("display_name", Path(app_name).stem)
        project.setdefault("bundle_identifier", None)
        project.setdefault("launch_script", None)
    return projects


def normalized_identifier(project: dict, used: set[str]) -> str:
    identifier = project.get("bundle_identifier")
    if not isinstance(identifier, str) or not identifier:
        slug = re.sub(r"[^a-z0-9]+", "-", project["layout_name"].lower()).strip("-")
        identifier = f"com.megasoft78.mica.project.{slug}"
    if identifier in used:
        slug = re.sub(r"[^a-z0-9]+", "-", project["layout_name"].lower()).strip("-")
        identifier = f"com.megasoft78.mica.project.{slug}"
    if identifier in used:
        raise RuntimeError(f"duplicate macOS bundle identifier for {project['app_name']}: {identifier}")
    used.add(identifier)
    return identifier


def install_bundle(project: dict, base_app: Path, used_ids: set[str], backup_dir: Path) -> None:
    target = Path(project["app_path"])
    target.parent.mkdir(parents=True, exist_ok=True)
    binary = base_app / "Contents/MacOS/Mica"
    icon = base_app / "Contents/Resources/Mica.icns"
    base_info = read_plist(base_app / "Contents/Info.plist")
    if not binary.is_file() or not icon.is_file():
        raise RuntimeError(f"build the base Mica.app before installing project apps: {base_app}")

    current_info = None
    if target.is_dir() and (target / "Contents/Info.plist").is_file():
        current_info = read_plist(target / "Contents/Info.plist")
    if current_info and current_info.get("MicaProjectLayoutName") == project["layout_name"]:
        project["bundle_identifier"] = project.get("bundle_identifier") or current_info.get("CFBundleIdentifier")
        if not project.get("launch_script"):
            project["launch_script"] = current_info.get("MicaProjectLaunchScript")

    identifier = normalized_identifier(project, used_ids)
    display_name = project["display_name"]
    info = dict(base_info)
    info.update({
        "CFBundleDisplayName": display_name,
        "CFBundleExecutable": "Mica",
        "CFBundleIconFile": "Mica.icns",
        "CFBundleIdentifier": identifier,
        "CFBundleName": display_name,
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "13.0",
        "NSPrincipalClass": "NSApplication",
        "MicaProjectName": display_name,
        "MicaProjectLayoutName": project["layout_name"],
        "MicaProjectLayout": project["layout_path"],
    })
    if project.get("launch_script"):
        info["MicaProjectLaunchScript"] = project["launch_script"]

    staging_parent = Path(tempfile.mkdtemp(prefix=f".{target.stem}.mica-", dir=target.parent))
    staging = staging_parent / target.name
    contents = staging / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    try:
        try:
            os.link(binary, contents / "MacOS/Mica")
        except OSError:
            shutil.copy2(binary, contents / "MacOS/Mica")
        shutil.copy2(icon, contents / "Resources/Mica.icns")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        (contents / "PkgInfo").write_bytes(b"APPL????")

        if target.exists():
            if not current_info or current_info.get("MicaProjectLayoutName") != project["layout_name"]:
                backup_dir.mkdir(parents=True, exist_ok=True)
                backup_path = backup_dir / target.name
                if backup_path.exists():
                    raise RuntimeError(f"refusing to overwrite existing launcher backup: {backup_path}")
                shutil.copytree(target, backup_path, symlinks=True)
            displaced = staging_parent / f"{target.name}.previous"
            os.replace(target, displaced)
            try:
                os.replace(staging, target)
            except Exception:
                os.replace(displaced, target)
                raise
            shutil.rmtree(displaced, ignore_errors=True)
        else:
            os.replace(staging, target)
    finally:
        shutil.rmtree(staging_parent, ignore_errors=True)
    project["bundle_identifier"] = identifier


def migrate_launch_script(project: dict, backup_dir: Path, install: bool) -> None:
    raw_path = project.get("launch_script")
    if not raw_path:
        return
    script_path = Path(raw_path)
    expected = f"exec /usr/bin/open -n {shlex.quote(project['app_path'])}"
    if not install:
        print(f"would route {script_path} to {project['app_name']}")
        return
    existing = script_path.read_text(encoding="utf-8") if script_path.is_file() else ""
    if expected in existing:
        return
    if script_path.is_file():
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_path = backup_dir / script_path.name
        if not backup_path.exists():
            shutil.copy2(script_path, backup_path)
    script_path.parent.mkdir(parents=True, exist_ok=True)
    script_path.write_text(
        "#!/bin/zsh\nset -eu\n\n"
        f"# Open the dedicated Mica app for {project['display_name']}.\n"
        f"{expected}\n",
        encoding="utf-8",
    )
    script_path.chmod(0o755)


def register_app_bundle(path: Path) -> None:
    registrar = Path(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        "LaunchServices.framework/Support/lsregister"
    )
    if registrar.is_file():
        result = subprocess.run([str(registrar), "-f", str(path)], capture_output=True, text=True)
        if result.returncode:
            print(f"warning: Launch Services could not refresh {path}: {result.stderr.strip()}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layouts", type=Path, default=DEFAULT_LAYOUTS)
    parser.add_argument("--launchers", type=Path, default=DEFAULT_DESKTOP)
    parser.add_argument("--output", type=Path, default=DEFAULT_DESKTOP)
    parser.add_argument("--base-app", type=Path, default=DEFAULT_BASE_APP)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--backups", type=Path, default=DEFAULT_BACKUPS)
    parser.add_argument("--install", action="store_true", help="install bundles and migrate matched shell launchers")
    args = parser.parse_args()

    try:
        layouts = args.layouts.expanduser().resolve()
        launchers = args.launchers.expanduser().resolve()
        output = args.output.expanduser().resolve()
        base_app = args.base_app.expanduser().resolve()
        manifest = args.manifest.expanduser().resolve()
        projects = load_projects(manifest, launchers, layouts, output)
        backup_dir = args.backups.expanduser().resolve() / datetime.now().strftime("%Y%m%d-%H%M%S")
        used_ids: set[str] = set()
        if args.install:
            # Save the complete launch map first so a partial install can resume safely.
            write_json_atomic(manifest, projects)
        for project in projects:
            existing = Path(project["app_path"])
            if existing.is_dir() and (existing / "Contents/Info.plist").is_file():
                info = read_plist(existing / "Contents/Info.plist")
                if info.get("MicaProjectLayoutName") == project["layout_name"]:
                    project["bundle_identifier"] = project.get("bundle_identifier") or info.get("CFBundleIdentifier")
                    project["launch_script"] = project.get("launch_script") or info.get("MicaProjectLaunchScript")
            if args.install:
                install_bundle(project, base_app, used_ids, backup_dir)
                register_app_bundle(Path(project["app_path"]))
                migrate_launch_script(project, backup_dir, True)
                print(f"installed {project['app_name']} [{project['bundle_identifier']}] -> {project['layout_name']}.mica")
            else:
                identifier = project.get("bundle_identifier") or normalized_identifier(project, used_ids)
                print(f"would install {project['app_name']} [{identifier}] -> {project['layout_name']}.mica")
                migrate_launch_script(project, backup_dir, False)
        if args.install:
            write_json_atomic(manifest, projects)
            print(f"backup copies: {backup_dir}")
            print(f"project manifest: {manifest}")
            print("The original active terminal sessions were left running.")
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"desktop app install failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
