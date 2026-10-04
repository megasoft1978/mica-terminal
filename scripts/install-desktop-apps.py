#!/usr/bin/env python3
"""Install lightweight project launchers for Mica layouts on macOS."""

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
DEFAULT_BASE_APP = (Path("/Applications/Mica.app") if Path("/Applications/Mica.app").is_dir()
                    else Path(__file__).resolve().parents[1] / "build/Mica.app")
DEFAULT_PROJECT_ICON_TOOL = Path(
    os.environ.get("MICA_PROJECT_ICON_TOOL", Path(__file__).resolve().parents[1] / "build/mica-project-icon")
)
DEFAULT_ICON_CONVERTER = Path(__file__).resolve().parent / "build-macos-icon.sh"
DEFAULT_MANIFEST = HOME / ".config/mica/desktop-apps.json"
DEFAULT_BACKUPS = HOME / ".local/share/mica/launcher-backups"


def launch_command(base_app: Path, layout_path: str, display_name: str) -> str:
    """The shell line a project launcher runs.

    Layouts in ~/.config/mica/layouts open as another window of the already running Mica (one process for all
    projects, which saves about 55 MB per extra window) through a mica:// URL that the app validates. Layouts
    kept elsewhere are not accepted by the app's URL handler, so they keep the older one-process-per-window path.
    """
    from urllib.parse import quote

    layout = Path(layout_path)
    try:
        inside_default = layout.resolve().is_relative_to(DEFAULT_LAYOUTS.resolve())
    except OSError:
        inside_default = False
    if inside_default:
        url = f"mica://open?layout={quote(str(layout.resolve()), safe='')}&name={quote(display_name, safe='')}"
        return f"exec /usr/bin/open -a {shlex.quote(str(base_app))} {shlex.quote(url)}"
    return (
        f"exec /usr/bin/open -n {shlex.quote(str(base_app))} --args "
        f"--layout {shlex.quote(layout_path)} "
        f"--project-name {shlex.quote(display_name)}"
    )


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def write_json_atomic(path: Path, payload: object) -> None:
    serialized = json.dumps(payload, indent=2) + "\n"
    if path.is_file() and path.read_text(encoding="utf-8") == serialized:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


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
    for launcher in sorted(launcher_dir.glob("*.mica")):
        try:
            layout_path = launcher.resolve(strict=True)
            layout_path.relative_to(layout_dir.resolve())
        except (OSError, ValueError):
            continue
        if not layout_path.is_file():
            continue
        projects.append({
            "app_name": launcher.name,
            "display_name": launcher.stem,
            "bundle_identifier": None,
            "layout_name": layout_path.stem,
            "layout_path": str(layout_path),
            "app_path": str(launcher),
            "launch_script": None,
        })
    if not projects:
        raise RuntimeError(
            f"no Desktop Mica launchers with matching .mica layouts were found in {launcher_dir}"
        )
    return projects


def load_projects(manifest: Path, launcher_dir: Path, layout_dir: Path, output_dir: Path) -> list[dict]:
    output_dir = output_dir.expanduser().resolve()
    layout_dir = layout_dir.expanduser().resolve()
    if manifest.is_file():
        records = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(records, list) or not records:
            raise RuntimeError(f"invalid or empty desktop app manifest: {manifest}")
        projects = records
        known_launchers = {item.get("app_name") for item in records if isinstance(item, dict)}
        # Recover project launchers created by older installer versions that were not written
        # to the manifest. The private MicaProjectLayoutName marker prevents touching other apps.
        for app in sorted(launcher_dir.glob("*.app")):
            if app.name in known_launchers:
                continue
            plist_path = app / "Contents/Info.plist"
            if not plist_path.is_file():
                continue
            info = read_plist(plist_path)
            layout_name = info.get("MicaProjectLayoutName")
            if (not isinstance(layout_name, str) or
                    not re.fullmatch(r"[A-Za-z0-9_-]+", layout_name) or
                    not (layout_dir / f"{layout_name}.mica").is_file()):
                continue
            projects.append({
                "app_name": app.name,
                "display_name": info.get("MicaProjectName") or info.get("CFBundleDisplayName") or app.stem,
                "bundle_identifier": info.get("CFBundleIdentifier"),
                "layout_name": layout_name,
                "launch_script": info.get("MicaProjectLaunchScript"),
            })
    else:
        projects = discover_launchers(launcher_dir, layout_dir)
    app_paths: set[str] = set()
    active_projects = []
    for project in projects:
        app_name = project.get("app_name")
        layout_name = project.get("layout_name")
        if (not isinstance(app_name, str) or Path(app_name).name != app_name
                or app_name in {".", ".."} or not app_name.endswith((".app", ".mica"))):
            raise RuntimeError(f"invalid launcher name in desktop manifest: {app_name!r}")
        legacy_name = app_name if app_name.endswith(".app") else None
        layout_name_file = Path(app_name).stem + ".mica"
        lexical_target = output_dir / layout_name_file
        if legacy_name:
            project["legacy_app_path"] = str(output_dir / legacy_name)
        project["app_name"] = layout_name_file
        if not isinstance(layout_name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", layout_name):
            raise RuntimeError(f"invalid layout name for {app_name}: {layout_name!r}")
        layout_path = layout_dir / f"{layout_name}.mica"
        if not layout_path.is_file():
            legacy_path = output_dir / app_name
            if legacy_path.exists() or legacy_path.is_symlink():
                raise RuntimeError(f"missing Mica layout for existing launcher {app_name}: {layout_path}")
            print(f"warning: skipping stale manifest entry {app_name}; layout is missing: {layout_path}", file=sys.stderr)
            continue
        project["layout_path"] = str(layout_path.resolve())
        project["app_path"] = str(lexical_target)
        if lexical_target.parent != output_dir.resolve():
            raise RuntimeError(f"project launcher path escapes output directory: {app_name!r}")
        if str(lexical_target) in app_paths:
            raise RuntimeError(f"duplicate project launcher target: {layout_name_file!r}")
        app_paths.add(str(lexical_target))
        project.setdefault("display_name", Path(app_name).stem)
        if (not isinstance(project["display_name"], str) or
                any(char in project["display_name"] for char in "\0\r\n")):
            raise RuntimeError(f"invalid project display name for {app_name}")
        project.setdefault("bundle_identifier", None)
        project.setdefault("launch_script", None)
        active_projects.append(project)
    return active_projects


def install_layout_launcher(project: dict, backup_dir: Path) -> None:
    """Install a Finder-openable .mica symlink to the canonical private layout."""
    target = Path(project["app_path"])
    layout = Path(project["layout_path"]).resolve(strict=True)
    if target.parent.resolve() != target.parent or not target.name.endswith(".mica"):
        raise RuntimeError(f"invalid Mica layout launcher path: {target}")
    if not layout.is_file() or layout.suffix.lower() != ".mica":
        raise RuntimeError(f"missing Mica layout file: {layout}")

    legacy_path = Path(project["legacy_app_path"]) if project.get("legacy_app_path") else None
    legacy_info = {}
    if legacy_path and os.path.lexists(legacy_path):
        if legacy_path.is_symlink() or not legacy_path.is_dir():
            raise RuntimeError(f"refusing to migrate unexpected legacy launcher: {legacy_path}")
        info_path = legacy_path / "Contents/Info.plist"
        legacy_info = read_plist(info_path) if info_path.is_file() else {}
        if legacy_info.get("MicaProjectLayoutName") != project["layout_name"]:
            raise RuntimeError(f"legacy app does not match its Mica layout: {legacy_path}")

    backup_dir.mkdir(parents=True, exist_ok=True)
    legacy_backup = backup_dir / legacy_path.name if legacy_path else None
    if legacy_backup and os.path.lexists(legacy_path) and (legacy_backup.exists() or legacy_backup.is_symlink()):
        raise RuntimeError(f"refusing to overwrite existing launcher backup: {legacy_backup}")

    if target.is_symlink() and target.resolve() == layout:
        pass
    elif os.path.lexists(target):
        backup = backup_dir / target.name
        if backup.exists() or backup.is_symlink():
            raise RuntimeError(f"refusing to overwrite existing launcher backup: {backup}")
        os.replace(target, backup)

    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    if os.path.lexists(temporary):
        raise RuntimeError(f"temporary launcher path already exists: {temporary}")
    os.symlink(layout, temporary)
    try:
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)

    if legacy_path and os.path.lexists(legacy_path):
        assert legacy_backup is not None
        shutil.copytree(legacy_path, legacy_backup, symlinks=True)
        shutil.rmtree(legacy_path)


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


def install_bundle(
    project: dict,
    base_app: Path,
    used_ids: set[str],
    backup_dir: Path,
    project_icon_tool: Path = DEFAULT_PROJECT_ICON_TOOL,
) -> None:
    target = Path(project["app_path"])
    if target == base_app.expanduser().resolve():
        raise RuntimeError(f"refusing to replace the shared Mica.app with a project launcher: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    binary = base_app / "Contents/MacOS/Mica"
    icon = base_app / "Contents/Resources/Mica.icns"
    if not binary.is_file() or not icon.is_file() or not project_icon_tool.is_file():
        raise RuntimeError(f"build the shared Mica.app before installing project launchers: {base_app}")
    base_info = read_plist(base_app / "Contents/Info.plist")

    current_info = None
    if target.is_symlink():
        raise RuntimeError(f"refusing to replace a symlink as a Mica launcher: {target}")
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
        "LSMinimumSystemVersion": "14.0",
        "NSPrincipalClass": "NSApplication",
        "MicaProjectName": display_name,
        "MicaProjectLayoutName": project["layout_name"],
        "MicaProjectLayout": project["layout_path"],
    })
    if project.get("launch_script"):
        info["MicaProjectLaunchScript"] = project["launch_script"]

    staging_parent = Path(tempfile.mkdtemp(prefix=f".{target.stem}.mica-", dir=target.parent))
    staging = staging_parent / target.name
    preserve_staging_parent = False
    contents = staging / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    try:
        # The project bundle remains a Finder-friendly icon and keeps its own
        # identity, but its tiny executable delegates to the one built app.
        # This avoids hardlink/copy snapshots that stay stale after `make app`.
        launcher = "#!/bin/sh\nset -eu\n\n" + launch_command(base_app.resolve(), project["layout_path"], display_name) + "\n"
        executable = contents / "MacOS/Mica"
        executable.write_text(launcher, encoding="utf-8")
        executable.chmod(0o755)
        project_icon_png = staging_parent / "Mica-project.png"
        subprocess.run(
            [str(project_icon_tool), str(icon), str(project_icon_png), display_name],
            check=True,
        )
        subprocess.run(
            [str(DEFAULT_ICON_CONVERTER), str(project_icon_png), str(contents / "Resources/Mica.icns")],
            check=True,
        )
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
            except Exception as install_error:
                try:
                    os.replace(displaced, target)
                except Exception as restore_error:
                    preserve_staging_parent = True
                    raise RuntimeError(
                        f"could not install {target} or restore its previous version; "
                        f"the previous launcher is preserved at {displaced}"
                    ) from restore_error
                raise install_error
            shutil.rmtree(displaced, ignore_errors=True)
        else:
            os.replace(staging, target)
    finally:
        if not preserve_staging_parent:
            shutil.rmtree(staging_parent, ignore_errors=True)
    project["bundle_identifier"] = identifier


def migrate_launch_script(
    project: dict, backup_dir: Path, install: bool, base_app: Path = DEFAULT_BASE_APP
) -> None:
    raw_path = project.get("launch_script")
    if not raw_path:
        return
    script_path = Path(raw_path)
    if not re.fullmatch(r"launch-[A-Za-z0-9_-]+\.sh", script_path.name):
        raise RuntimeError(f"refusing to migrate an unexpected launcher script path: {script_path}")
    if script_path.is_symlink():
        raise RuntimeError(f"refusing to migrate a symlink launcher script: {script_path}")
    base_app = base_app.expanduser().resolve()
    display_name = project["display_name"]
    if not isinstance(display_name, str) or any(char in display_name for char in "\0\r\n"):
        raise RuntimeError(f"invalid project display name for {project['app_name']}")
    expected = launch_command(base_app, project["layout_path"], project["display_name"])
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
        "# Open a project in the shared Mica build.\n"
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


def validate_layout_migrations(projects: list[dict]) -> None:
    """Check every legacy launcher before the installer changes any Desktop entries."""
    for project in projects:
        target = Path(project["app_path"])
        if target.name != project["app_name"] or not target.name.endswith(".mica"):
            raise RuntimeError(f"invalid Mica layout launcher path: {target}")
        if target.is_symlink() and target.resolve() == Path(project["layout_path"]).resolve():
            pass
        legacy_raw = project.get("legacy_app_path")
        if not legacy_raw or not os.path.lexists(legacy_raw):
            continue
        legacy = Path(legacy_raw)
        if legacy.is_symlink() or not legacy.is_dir():
            raise RuntimeError(f"refusing to migrate unexpected legacy launcher: {legacy}")
        info_path = legacy / "Contents/Info.plist"
        info = read_plist(info_path) if info_path.is_file() else {}
        if info.get("MicaProjectLayoutName") != project["layout_name"]:
            raise RuntimeError(f"legacy app does not match its Mica layout: {legacy}")


def create_instance_record(name: str, cwd: Path, command: str, layout_dir: Path, output_dir: Path) -> dict:
    display_name = name.strip()
    if not display_name or any(ord(char) < 0x20 or ord(char) == 0x7f or char in "/\\" for char in display_name):
        raise ValueError("instance name must be non-empty and cannot contain control characters or slashes")
    slug = re.sub(r"[^a-z0-9]+", "-", display_name.lower()).strip("-")
    if not slug:
        raise ValueError("instance name must include at least one letter or number")
    if any(char in command for char in "\t\r\n\0"):
        raise ValueError("startup command cannot contain tabs, newlines, or NUL characters")

    project_dir = cwd.expanduser().resolve(strict=True)
    if not project_dir.is_dir():
        raise ValueError(f"project folder is not a directory: {project_dir}")
    if any(char in str(project_dir) for char in "\t\r\n\0"):
        raise ValueError("project folder path cannot contain tabs or newlines")
    layout_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    layout_dir = layout_dir.resolve()
    output_dir = output_dir.resolve()
    layout_path = layout_dir / f"{slug}.mica"
    app_name = f"{slug}.mica"
    app_path = output_dir / app_name
    if os.path.lexists(app_path):
        raise FileExistsError(f"Mica layout launcher already exists: {app_path}")
    if layout_path.exists():
        raise FileExistsError(f"Mica layout already exists: {layout_path}")

    layout_contents = f"# Mica layout v1\n# Mica project: {display_name}\nShell\t{project_dir}\t{command.strip()}\n"
    created_layout = False
    try:
        with layout_path.open("x", encoding="utf-8") as stream:
            created_layout = True
            stream.write(layout_contents)
    except Exception:
        if created_layout:
            layout_path.unlink(missing_ok=True)
        raise
    return {
        "app_name": app_name,
        "display_name": display_name,
        "bundle_identifier": None,
        "layout_name": slug,
        "layout_path": str(layout_path.resolve()),
        "app_path": str(app_path),
        "launch_script": None,
    }


def create_instance_from_prompts(
    layouts: Path,
    output: Path,
    base_app: Path,
    manifest: Path,
    project_icon_tool: Path,
    register: bool = True,
    name: str | None = None,
    folder: str | None = None,
    command: str | None = None,
) -> dict:
    cwd = Path.cwd().resolve()
    default_name = cwd.name or "Mica Project"
    # Any of name/folder/command given on the command line makes the run non-interactive.
    if name is not None or folder is not None or command is not None:
        name = (name or default_name).strip() or default_name
        project_dir = Path(folder).expanduser() if folder else cwd
        command = (command or "").strip()
    else:
        name = input(f"Name for this Mica instance [{default_name}]: ").strip() or default_name
        folder_text = input(f"Project folder [{cwd}]: ").strip()
        project_dir = Path(folder_text).expanduser() if folder_text else cwd
        command = input("Startup command (optional; leave blank for a shell): ").strip()

    existing = []
    if manifest.is_file():
        existing = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(existing, list) or any(not isinstance(item, dict) for item in existing):
            raise ValueError(f"invalid desktop app manifest: {manifest}")
    project = create_instance_record(name, project_dir, command, layouts, output)
    launcher_installed = False
    try:
        for item in existing:
            old_name = item.get("app_name")
            if (old_name == project["app_name"] or
                    (isinstance(old_name, str) and Path(old_name).stem == project["layout_name"]) or
                    item.get("layout_name") == project["layout_name"]):
                raise FileExistsError(f"Mica instance already exists: {project['display_name']}")
        install_layout_launcher(project, Path(tempfile.gettempdir()))
        launcher_installed = True
        all_projects = [*existing, project]
        write_json_atomic(manifest, all_projects)
    except Exception:
        # Once installed, keep the layout and Desktop symlink together if the manifest write fails.
        if not launcher_installed:
            Path(project["layout_path"]).unlink(missing_ok=True)
        raise
    if register:
        register_app_bundle(base_app)
    return project


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layouts", type=Path, default=DEFAULT_LAYOUTS)
    parser.add_argument("--launchers", type=Path, default=DEFAULT_DESKTOP)
    parser.add_argument("--output", type=Path, default=DEFAULT_DESKTOP)
    parser.add_argument("--base-app", type=Path, default=DEFAULT_BASE_APP)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--backups", type=Path, default=DEFAULT_BACKUPS)
    parser.add_argument("--project-icon-tool", type=Path, default=DEFAULT_PROJECT_ICON_TOOL)
    parser.add_argument("--new-instance", action="store_true", help="create a project layout and Desktop .mica launcher")
    parser.add_argument("--name", help="with --new-instance: project name (skips the prompts)")
    parser.add_argument("--folder", help="with --new-instance: project folder (skips the prompts)")
    parser.add_argument("--command", help="with --new-instance: optional startup command (skips the prompts)")
    parser.add_argument("--no-register", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--install", action="store_true", help="install .mica Desktop launchers and migrate matched shell scripts")
    args = parser.parse_args()

    try:
        layouts = args.layouts.expanduser().resolve()
        launchers = args.launchers.expanduser().resolve()
        output = args.output.expanduser().resolve()
        base_app = args.base_app.expanduser().resolve()
        manifest = args.manifest.expanduser().resolve()
        project_icon_tool = args.project_icon_tool.expanduser().resolve()
        if args.new_instance:
            project = create_instance_from_prompts(
                layouts, output, base_app, manifest, project_icon_tool, register=not args.no_register,
                name=args.name, folder=args.folder, command=args.command,
            )
            print(f"created {project['app_path']}")
            print(f"layout: {project['layout_path']}")
            if project["layout_path"] and Path(project["layout_path"]).read_text(encoding="utf-8").splitlines()[-1].endswith("\t"):
                print("The new app opens a zsh shell in this folder.")
            else:
                print("The startup command is prefilled in the shell; press Return to run it.")
            return 0
        projects = load_projects(manifest, launchers, layouts, output)
        backup_dir = args.backups.expanduser().resolve() / datetime.now().strftime("%Y%m%d-%H%M%S")
        if args.install:
            validate_layout_migrations(projects)
            # Save the complete launch map first so a partial install can resume safely.
            write_json_atomic(manifest, projects)
        if args.install:
            register_app_bundle(base_app)
        for project in projects:
            if args.install:
                install_layout_launcher(project, backup_dir)
                migrate_launch_script(project, backup_dir, True, base_app)
                print(f"installed {project['app_name']} -> {project['layout_name']}.mica")
            else:
                print(f"would install {project['app_name']} -> {project['layout_name']}.mica")
                migrate_launch_script(project, backup_dir, False, base_app)
        if args.install:
            write_json_atomic(manifest, projects)
            print(f"backup copies: {backup_dir}")
            print(f"project manifest: {manifest}")
            print("The original active terminal sessions were left running.")
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"desktop app install failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
