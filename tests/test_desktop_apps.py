#!/usr/bin/env python3
"""Package checks for per-project Mica app identities and launcher migration."""

import importlib.util
import plistlib
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "mica_desktop_apps", ROOT / "scripts" / "install-desktop-apps.py"
)
assert SPEC and SPEC.loader
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


def write_plist(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        plistlib.dump(value, stream)


def make_base_app(path: Path) -> None:
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Resources").mkdir()
    (path / "Contents/Helpers").mkdir()
    (path / "Contents/MacOS/Mica").write_bytes(b"shared-mica-executable")
    helper = path / "Contents/Helpers/mica-voice"
    helper.write_bytes(b"local-voice-helper")
    helper.chmod(0o755)
    icon_path = Path(os.environ.get(
        "MICA_TEST_APP_ICON", ROOT / "build/Mica.app/Contents/Resources/Mica.icns"
    ))
    (path / "Contents/Resources/Mica.icns").write_bytes(icon_path.read_bytes())
    (path / "Contents/Resources/THIRD_PARTY_NOTICES.md").write_text("model and runtime credits\n", encoding="utf-8")
    (path / "Contents/Resources/ThirdPartyLicenses").mkdir()
    (path / "Contents/Resources/ThirdPartyLicenses/example.txt").write_text("test license\n", encoding="utf-8")
    (path / "Contents/Resources/LICENSE-FluidAudio.txt").write_text("Apache License\n", encoding="utf-8")
    write_plist(path / "Contents/Info.plist", {
        "CFBundleDisplayName": "Mica Terminal",
        "CFBundleExecutable": "Mica",
        "CFBundleIdentifier": "com.megasoft78.mica-terminal",
        "CFBundleName": "Mica",
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "14.0",
        "NSMicrophoneUsageDescription": "Dictation microphone test notice",
        "NSDesktopFolderUsageDescription": "Project folder access test notice",
        "NSDocumentsFolderUsageDescription": "Project folder access test notice",
        "NSPrincipalClass": "NSApplication",
    })


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mica-desktop-apps-") as temporary:
        root = Path(temporary)
        base_app = root / "Mica.app"
        layout_dir = root / "layouts"
        output = root / "Desktop"
        backups = root / "backups"
        layout_dir.mkdir()
        output.mkdir()
        make_base_app(base_app)
        (layout_dir / "alpha.mica").write_text("# Mica layout v1\nShell\t/tmp\t\n", encoding="utf-8")
        (layout_dir / "beta.mica").write_text("# Mica layout v1\nCodex\t/tmp\t\n", encoding="utf-8")

        malicious_manifest = root / "malicious-manifest.json"
        malicious_manifest.write_text(json.dumps([{
            "app_name": "../Outside.app",
            "layout_name": "alpha",
        }]), encoding="utf-8")
        try:
            INSTALLER.load_projects(malicious_manifest, output, layout_dir, output)
            raise AssertionError("installer accepted an app path outside its output directory")
        except RuntimeError as error:
            assert "invalid app name" in str(error)

        malicious_script = root / "launch-malicious.sh"
        try:
            INSTALLER.migrate_launch_script({
                "launch_script": str(malicious_script),
                "display_name": "Project\n touch /tmp/mica-installer-injected",
                "app_name": "Alpha.app",
                "layout_path": str((layout_dir / "alpha.mica").resolve()),
            }, root / "backups", True, base_app)
            raise AssertionError("installer accepted a newline in the project name")
        except RuntimeError as error:
            assert "invalid project display name" in str(error)
        assert not malicious_script.exists()

        old_app = output / "Alpha.app"
        write_plist(old_app / "Contents/Info.plist", {
            "CFBundleName": "Alpha",
            "CFBundlePackageType": "APPL",
        })
        (old_app / "Contents/Resources/Scripts").mkdir(parents=True)
        (old_app / "Contents/Resources/Scripts/main.scpt").write_bytes(b"old launcher script")
        launch_script = root / "launch-alpha.sh"
        original_launcher = "#!/bin/zsh\nprintf 'OLD-LAUNCHER\\n'\n"
        launch_script.write_text(original_launcher, encoding="utf-8")

        projects = [
            {
                "app_name": "Alpha.app",
                "display_name": "Alpha Project",
                "bundle_identifier": None,
                "layout_name": "alpha",
                "layout_path": str((layout_dir / "alpha.mica").resolve()),
                "app_path": str(old_app.resolve()),
                "launch_script": str(launch_script),
            },
            {
                "app_name": "Beta.app",
                "display_name": "Beta Project",
                "bundle_identifier": "com.example.beta",
                "layout_name": "beta",
                "layout_path": str((layout_dir / "beta.mica").resolve()),
                "app_path": str((output / "Beta.app").resolve()),
                "launch_script": None,
            },
        ]
        used_ids: set[str] = set()
        for project in projects:
            INSTALLER.install_bundle(project, base_app, used_ids, backups)

        recovery_target = output / "Recovery.app"
        (recovery_target / "Contents").mkdir(parents=True)
        (recovery_target / "Contents/original.txt").write_text("keep me", encoding="utf-8")
        recovery_project = {
            "app_name": "Recovery.app",
            "display_name": "Recovery Project",
            "bundle_identifier": None,
            "layout_name": "recovery",
            "layout_path": str((layout_dir / "alpha.mica").resolve()),
            "app_path": str(recovery_target),
            "launch_script": None,
        }
        real_replace = INSTALLER.os.replace
        replace_calls = 0

        def fail_install_and_restore(source: Path, destination: Path) -> None:
            nonlocal replace_calls
            replace_calls += 1
            if replace_calls == 2:
                recovery_target.mkdir()
                (recovery_target / "concurrent-writer.txt").write_text("present", encoding="utf-8")
                raise OSError("simulated concurrent target creation")
            if replace_calls == 3:
                raise OSError("simulated restore failure")
            real_replace(source, destination)

        INSTALLER.os.replace = fail_install_and_restore
        try:
            try:
                INSTALLER.install_bundle(recovery_project, base_app, set(), backups)
                raise AssertionError("launcher install unexpectedly succeeded after both renames failed")
            except RuntimeError as error:
                assert "previous launcher is preserved at" in str(error)
                preserved_path = Path(str(error).rsplit(" ", 1)[-1])
                assert (preserved_path / "Contents/original.txt").read_text(encoding="utf-8") == "keep me"
        finally:
            INSTALLER.os.replace = real_replace

        alpha_info = INSTALLER.read_plist(old_app / "Contents/Info.plist")
        beta_info = INSTALLER.read_plist(output / "Beta.app/Contents/Info.plist")
        assert alpha_info["CFBundleIdentifier"] == "com.megasoft78.mica.project.alpha"
        assert beta_info["CFBundleIdentifier"] == "com.example.beta"
        assert alpha_info["CFBundleIdentifier"] != beta_info["CFBundleIdentifier"]
        assert alpha_info["CFBundleIconFile"] == "Mica.icns"
        assert beta_info["CFBundleIconFile"] == "Mica.icns"
        assert alpha_info["NSMicrophoneUsageDescription"] == "Dictation microphone test notice"
        assert alpha_info["NSDesktopFolderUsageDescription"] == "Project folder access test notice"
        assert alpha_info["NSDocumentsFolderUsageDescription"] == "Project folder access test notice"
        assert alpha_info["MicaProjectName"] == "Alpha Project"
        assert alpha_info["MicaProjectLayout"] == str((layout_dir / "alpha.mica").resolve())
        assert beta_info["MicaProjectLayoutName"] == "beta"
        for app in (old_app, output / "Beta.app"):
            launcher = app / "Contents/MacOS/Mica"
            assert launcher.read_text(encoding="utf-8").startswith("#!/bin/sh\n")
            assert os.access(launcher, os.X_OK)
            assert f"open -n {shlex.quote(str(base_app.resolve()))} --args" in launcher.read_text(encoding="utf-8")
            assert "--layout" in launcher.read_text(encoding="utf-8")
            assert "--project-name" in launcher.read_text(encoding="utf-8")
            assert not (app / "Contents/Helpers").exists()
        alpha_icon = (old_app / "Contents/Resources/Mica.icns").read_bytes()
        beta_icon = (output / "Beta.app/Contents/Resources/Mica.icns").read_bytes()
        assert alpha_icon.startswith(b"icns") and beta_icon.startswith(b"icns")
        assert alpha_icon != beta_icon, "each project app should have its own marked icon"
        decoded_iconset = root / "Alpha.iconset"
        subprocess.run(
            ["iconutil", "--convert", "iconset", "--output", str(decoded_iconset),
             str(old_app / "Contents/Resources/Mica.icns")],
            check=True,
        )
        assert (decoded_iconset / "icon_512x512@2x.png").is_file()
        assert (old_app / "Contents/Resources/Scripts/main.scpt").is_file() is False
        backed_up_app = backups / "Alpha.app"
        assert (backed_up_app / "Contents/Resources/Scripts/main.scpt").read_bytes() == b"old launcher script"
        INSTALLER.migrate_launch_script(projects[0], backups, True, base_app)
        new_script = launch_script.read_text(encoding="utf-8")
        assert "open -n" in new_script and str(base_app.resolve()) in new_script
        assert "--layout" in new_script and "--project-name 'Alpha Project'" in new_script
        assert (backups / "launch-alpha.sh").read_text(encoding="utf-8") == original_launcher

    # Layouts in the default folder open as a window of the running app through a mica:// URL; others keep open -n.
    default_layout = INSTALLER.DEFAULT_LAYOUTS / "my project.mica"
    url_command = INSTALLER.launch_command(Path("/Applications/Mica.app"), str(default_layout), "My Project & Co")
    assert url_command.startswith("exec /usr/bin/open -a /Applications/Mica.app 'mica://open?layout=")
    assert "%20project.mica" in url_command and "name=My%20Project%20%26%20Co" in url_command and "--args" not in url_command
    legacy_command = INSTALLER.launch_command(Path("/Applications/Mica.app"), "/tmp/elsewhere.mica", "Elsewhere")
    assert "open -n" in legacy_command and "--layout /tmp/elsewhere.mica" in legacy_command

    with tempfile.TemporaryDirectory(prefix="mica-new-instance-") as temporary:
        root = Path(temporary)
        base_app = root / "Mica.app"
        layout_dir = root / "config" / "layouts"
        desktop = root / "Desktop"
        manifest = root / "config" / "desktop-apps.json"
        project_folder = root / "A project folder"
        project_folder.mkdir()
        desktop.mkdir()
        escaped_target = root / "Outside.app"
        (desktop / "demo-project.app").symlink_to(escaped_target)
        try:
            INSTALLER.create_instance_record("Demo Project", project_folder, "", layout_dir, desktop)
            raise AssertionError("new-instance accepted a symlink launcher target")
        except FileExistsError as error:
            assert "symlink" in str(error)
        assert not (layout_dir / "demo-project.mica").exists()
        (desktop / "demo-project.app").unlink()
        make_base_app(base_app)
        icon_tool = Path(os.environ.get("MICA_PROJECT_ICON_TOOL", INSTALLER.DEFAULT_PROJECT_ICON_TOOL))
        create = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "install-desktop-apps.py"),
                "--new-instance",
                "--no-register",
                "--layouts", str(layout_dir),
                "--output", str(desktop),
                "--manifest", str(manifest),
                "--base-app", str(base_app),
                "--project-icon-tool", str(icon_tool),
            ],
            input=f"Demo Project\n{project_folder}\n\n",
            text=True,
            capture_output=True,
            check=True,
        )
        layout = layout_dir / "demo-project.mica"
        app = desktop / "demo-project.app"
        assert layout.read_text(encoding="utf-8") == (
            f"# Mica layout v1\n# Mica project: Demo Project\nShell\t{project_folder.resolve()}\t\n"
        )
        app_info = INSTALLER.read_plist(app / "Contents/Info.plist")
        assert app_info["CFBundleDisplayName"] == "Demo Project"
        assert app_info["MicaProjectLayout"] == str(layout.resolve())
        assert app_info["CFBundleIdentifier"] == "com.megasoft78.mica.project.demo-project"
        launcher = app / "Contents/MacOS/Mica"
        assert str(base_app.resolve()) in launcher.read_text(encoding="utf-8")
        assert "--layout" in launcher.read_text(encoding="utf-8")
        assert not (app / "Contents/Resources/Scripts/main.scpt").exists()
        assert json.loads(manifest.read_text(encoding="utf-8"))[0]["launch_script"] is None
        assert "created " in create.stdout and "opens a zsh shell" in create.stdout

        # The same launcher can be created without prompts, which is how a GUI would drive it.
        flag_root = root / "flag-run"
        flag_desktop = flag_root / "Desktop"
        flag_desktop.mkdir(parents=True)
        flag_run = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "install-desktop-apps.py"),
                "--new-instance",
                "--no-register",
                "--name", "Flag Project",
                "--folder", str(project_folder),
                "--command", "codex",
                "--layouts", str(flag_root / "layouts"),
                "--output", str(flag_desktop),
                "--manifest", str(flag_root / "desktop-apps.json"),
                "--base-app", str(base_app),
                "--project-icon-tool", str(icon_tool),
            ],
            stdin=subprocess.DEVNULL,
            text=True,
            capture_output=True,
            check=True,
        )
        flag_layout = (flag_root / "layouts" / "flag-project.mica").read_text(encoding="utf-8")
        assert flag_layout.endswith(f"Shell\t{project_folder.resolve()}\tcodex\n"), flag_layout
        assert (flag_desktop / "flag-project.app").is_dir() and "created " in flag_run.stdout

        conflict = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "install-desktop-apps.py"),
                "--new-instance",
                "--no-register",
                "--layouts", str(layout_dir),
                "--output", str(desktop),
                "--manifest", str(manifest),
                "--base-app", str(base_app),
                "--project-icon-tool", str(icon_tool),
            ],
            input=f"Demo Project\n{project_folder}\n\n",
            text=True,
            capture_output=True,
        )
        assert conflict.returncode != 0
        assert app.is_dir() and layout.is_file()
        assert len(json.loads(manifest.read_text(encoding="utf-8"))) == 1

        command_create = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "install-desktop-apps.py"),
                "--new-instance",
                "--no-register",
                "--layouts", str(layout_dir),
                "--output", str(desktop),
                "--manifest", str(manifest),
                "--base-app", str(base_app),
                "--project-icon-tool", str(icon_tool),
            ],
            input=f"Agent Project\n{project_folder}\ncodex\n",
            text=True,
            capture_output=True,
            check=True,
        )
        command_layout = layout_dir / "agent-project.mica"
        command_app = desktop / "agent-project.app"
        assert command_layout.read_text(encoding="utf-8") == (
            f"# Mica layout v1\n# Mica project: Agent Project\nShell\t{project_folder.resolve()}\tcodex\n"
        )
        assert INSTALLER.read_plist(command_app / "Contents/Info.plist")["MicaProjectLayout"] == str(command_layout.resolve())
        assert "prefilled in the shell" in command_create.stdout
        assert len(json.loads(manifest.read_text(encoding="utf-8"))) == 2

    print("desktop app packaging tests passed")


if __name__ == "__main__":
    main()
