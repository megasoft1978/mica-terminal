#!/usr/bin/env python3
"""Package checks for per-project Mica app identities and launcher migration."""

import importlib.util
import plistlib
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
    (path / "Contents/MacOS/Mica").write_bytes(b"shared-mica-executable")
    (path / "Contents/Resources/Mica.icns").write_bytes(
        (ROOT / "build/Mica.app/Contents/Resources/Mica.icns").read_bytes()
    )
    write_plist(path / "Contents/Info.plist", {
        "CFBundleDisplayName": "Mica Terminal",
        "CFBundleExecutable": "Mica",
        "CFBundleIdentifier": "com.megasoft78.mica-terminal",
        "CFBundleName": "Mica",
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "13.0",
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

        alpha_info = INSTALLER.read_plist(old_app / "Contents/Info.plist")
        beta_info = INSTALLER.read_plist(output / "Beta.app/Contents/Info.plist")
        assert alpha_info["CFBundleIdentifier"] == "com.megasoft78.mica.project.alpha"
        assert beta_info["CFBundleIdentifier"] == "com.example.beta"
        assert alpha_info["CFBundleIdentifier"] != beta_info["CFBundleIdentifier"]
        assert alpha_info["CFBundleIconFile"] == "Mica.icns"
        assert beta_info["CFBundleIconFile"] == "Mica.icns"
        assert alpha_info["MicaProjectName"] == "Alpha Project"
        assert alpha_info["MicaProjectLayout"] == str((layout_dir / "alpha.mica").resolve())
        assert beta_info["MicaProjectLayoutName"] == "beta"
        alpha_icon = (old_app / "Contents/Resources/Mica.icns").read_bytes()
        beta_icon = (output / "Beta.app/Contents/Resources/Mica.icns").read_bytes()
        assert alpha_icon.startswith(b"icns") and beta_icon.startswith(b"icns")
        assert alpha_icon != beta_icon, "each project app should have its own marked icon"
        assert (old_app / "Contents/Resources/Scripts/main.scpt").is_file() is False
        try:
            assert (old_app / "Contents/MacOS/Mica").samefile(base_app / "Contents/MacOS/Mica")
            assert (output / "Beta.app/Contents/MacOS/Mica").samefile(base_app / "Contents/MacOS/Mica")
        except OSError:
            assert (old_app / "Contents/MacOS/Mica").read_bytes() == b"shared-mica-executable"
            assert (output / "Beta.app/Contents/MacOS/Mica").read_bytes() == b"shared-mica-executable"

        backed_up_app = backups / "Alpha.app"
        assert (backed_up_app / "Contents/Resources/Scripts/main.scpt").read_bytes() == b"old launcher script"
        INSTALLER.migrate_launch_script(projects[0], backups, True)
        new_script = launch_script.read_text(encoding="utf-8")
        assert "open -n" in new_script and "Alpha.app" in new_script
        assert (backups / "launch-alpha.sh").read_text(encoding="utf-8") == original_launcher

    print("desktop app packaging tests passed")


if __name__ == "__main__":
    main()
