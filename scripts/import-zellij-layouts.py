#!/usr/bin/env python3
"""Convert Mica's current Zellij layout subset into tab-per-session .mica files."""
import argparse
import json
import re
from pathlib import Path

STRING = r'"(?:\\.|[^"\\])*"'
TAB_RE = re.compile(r'^\s*tab\s+name\s*=\s*(' + STRING + r')[^{]*\{(.*?)^\s*\}', re.S | re.M)


def decode(value: str) -> str:
    return json.loads(value)


def field(block: str, name: str) -> str:
    match = re.search(r'\b' + re.escape(name) + r'\s+(' + STRING + r')', block)
    return decode(match.group(1)) if match else ""


def convert(source: Path, destination: Path) -> int:
    destination.mkdir(parents=True, exist_ok=True)
    count = 0
    for layout in sorted(source.glob("*.kdl")):
        tabs = []
        content = layout.read_text(encoding="utf-8")
        for match in TAB_RE.finditer(content):
            name = decode(match.group(1))
            body = match.group(2)
            cwd = field(body, "cwd")
            command = field(body, "args")
            if not command:
                direct_command = field(body, "command")
                if direct_command and Path(direct_command).name != "prefill.sh":
                    command = direct_command
            tabs.append("\t".join((name, cwd, command)))
        if not tabs:
            continue
        target = destination / f"{layout.stem}.mica"
        target.write_text("# Mica layout v1\n" + "\n".join(tabs) + "\n", encoding="utf-8")
        count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?", default=Path.home() / ".config/zellij/layouts",
                        help="Directory containing Zellij .kdl layouts")
    parser.add_argument("destination", type=Path, nargs="?", default=Path.home() / ".config/mica/layouts",
                        help="Directory for generated .mica files")
    args = parser.parse_args()
    count = convert(args.source.expanduser(), args.destination.expanduser())
    print(f"Converted {count} layout(s) into {args.destination.expanduser()}")


if __name__ == "__main__":
    main()
