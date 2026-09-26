#!/usr/bin/env python3
"""Unit checks for the tab-only subset imported from the user's Zellij layouts."""

import importlib.util
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "mica_layout_importer", ROOT / "scripts" / "import-zellij-layouts.py"
)
assert SPEC and SPEC.loader
IMPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORTER)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mica-layout-test-") as temporary:
        root = Path(temporary)
        source = root / "zellij"
        destination = root / "mica"
        source.mkdir()
        (source / "example.kdl").write_text(
            r'''layout {
    default_tab_template {
        pane size=1 borderless=true { plugin location="zellij:tab-bar" }
        children
        pane size=2 borderless=true { plugin location="zellij:status-bar" }
    }
    tab name="Claude Code" focus=true {
        pane {
            command "/Users/test/.config/zellij/prefill.sh"
            args "unset CLAUDECODE && yowork --continue"
            cwd "/tmp/project with spaces"
        }
    }
    tab name="Explorer" {
        pane {
            command "/Users/test/.config/zellij/prefill.sh"
            args "yazi"
            cwd "/tmp/project with spaces"
        }
    }
    tab name="Shell" {
        pane {
            cwd "/tmp/a \"quoted\" project"
        }
    }
}
''',
            encoding="utf-8",
        )

        converted = IMPORTER.convert(source, destination)
        assert converted == 1
        output = (destination / "example.mica").read_text(encoding="utf-8").splitlines()
        assert output[0] == "# Mica layout v1"
        assert output[1:] == [
            "Claude Code\t/tmp/project with spaces\tunset CLAUDECODE && yowork --continue",
            "Explorer\t/tmp/project with spaces\tyazi",
            'Shell\t/tmp/a "quoted" project\t',
        ]

    print("layout importer tests passed")


if __name__ == "__main__":
    main()
