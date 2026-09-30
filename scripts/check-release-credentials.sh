#!/bin/bash
# Distribution releases must be signed and notarized. Never print secret values.
set -eu
missing=0
for key in CERT_P12 CERT_PASSWORD APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [ -z "${!key:-}" ]; then
        echo "::error::Missing required release credential: $key" >&2
        missing=1
    fi
done
exit "$missing"
