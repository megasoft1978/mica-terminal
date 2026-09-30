#!/usr/bin/env python3
"""Exercise release credential failures locally without calling Apple or GitHub."""
import os
from pathlib import Path
import subprocess

script = Path(__file__).resolve().parents[1] / "scripts/check-release-credentials.sh"
keys = ("CERT_P12", "CERT_PASSWORD", "APPLE_ID", "APPLE_TEAM_ID", "APPLE_APP_PASSWORD")
base = {key: value for key, value in os.environ.items() if key not in keys}
credentials = {key: f"private-test-value-{index}" for index, key in enumerate(keys)}

def check(values, missing):
    result = subprocess.run([str(script)], env={**base, **values}, capture_output=True, text=True)
    assert result.returncode == (1 if missing else 0), result.stderr
    assert all(value not in result.stdout + result.stderr for value in credentials.values())
    for key in keys:
        assert (f"credential: {key}" in result.stderr) == (key in missing), result.stderr

check({}, set(keys))
check(credentials, set())
for key in keys:
    absent = dict(credentials)
    del absent[key]
    check(absent, {key})
    check({**credentials, key: ""}, {key})
print("release credential tests passed")
