#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_binary="$repo_root/build/Mica.app/Contents/MacOS/Mica"
fixture="$repo_root/examples/mica-demo"

if [ ! -x "$app_binary" ]; then
    (cd "$repo_root" && make app)
fi

demo_workspace=$(mktemp -d "${TMPDIR:-/tmp}/mica-demo.XXXXXX")
cp -R "$fixture"/. "$demo_workspace"/
git -C "$demo_workspace" init -q
git -C "$demo_workspace" config user.name "Mica Demo"
git -C "$demo_workspace" config user.email "mica-demo@example.invalid"
git -C "$demo_workspace" add index.html styles.css app.js README.md
git -C "$demo_workspace" commit -q -m "Add fictional Fieldnote project board"
demo_home="$demo_workspace/home"
mkdir -p "$demo_home"

layout=$(mktemp "$repo_root/examples/.mica-demo.XXXXXX")
trap 'rm -f "$layout"' EXIT HUP INT TERM
printf '# Mica project: Mica Demo\nPreview\t%s\tpython3 -m http.server 4173 --bind 127.0.0.1\nCodex\t%s\tcodex -s workspace-write -a never\nGit\t%s\tlazygit\nShell\t%s\t\n' \
    "$demo_workspace" "$demo_workspace" "$demo_workspace" "$demo_workspace" > "$layout"

# This demo-only environment gives each shell a clean zsh prompt, isolates app
# state, and skips personal startup files. Commands stay in the disposable copy.
open -n -a "$repo_root/build/Mica.app" \
    --env "HOME=$demo_home" --env "ZDOTDIR=$demo_home" --env MICA_TEST_NO_STARTUP=1 \
    --args --layout "$layout" --project-name "Mica Demo"
sleep 2
rm -f "$layout"
trap - EXIT HUP INT TERM

printf 'Mica Demo is running.\n'
printf 'Temporary project: %s\n' "$demo_workspace"
printf 'Start Codex or the preview from its prefilled tab.\n'
printf 'Remove the temporary project when finished:\n  rm -rf %s\n' "$demo_workspace"
