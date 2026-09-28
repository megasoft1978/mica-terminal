#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_binary="$repo_root/build/Mica.app/Contents/MacOS/Mica"
fixture="$repo_root/examples/mica-demo"

if [ ! -x "$app_binary" ]; then
    (cd "$repo_root" && make app)
fi

demo_workspace=$(mktemp -d "/tmp/mica-demo.XXXXXX")
cp -R "$fixture"/. "$demo_workspace"/
git -C "$demo_workspace" init -q
git -C "$demo_workspace" config user.name "Mica Demo"
git -C "$demo_workspace" config user.email "mica-demo@example.invalid"
git -C "$demo_workspace" add index.html styles.css app.js README.md
git -C "$demo_workspace" commit -q -m "Add fictional Fieldnote project board"
demo_home=$(mktemp -d "/tmp/mica-demo-home.XXXXXX")
mkdir -p "$demo_home"
cat > "$demo_home/.zshrc" <<'ZSHRC'
PROMPT='fieldnote%# '
PS1=$PROMPT
RPROMPT=''
ZSHRC
demo_codex_home="$demo_home/.codex"
mkdir -p "$demo_codex_home"
if [ -f "$HOME/.codex/auth.json" ]; then
    cp "$HOME/.codex/auth.json" "$demo_codex_home/auth.json"
    chmod 600 "$demo_codex_home/auth.json"
fi

layout=$(mktemp "$repo_root/examples/.mica-demo.XXXXXX")
trap 'rm -f "$layout"' EXIT HUP INT TERM
codex_demo_command='codex -s workspace-write -a never'
if [ "${1:-}" = "--codex" ]; then
    codex_demo_command="codex exec --ignore-user-config --approve-for-me 'In this fictional Fieldnote demo project, update only app.js so every filter button keeps its aria-pressed value synchronized with the selected filter. Preserve current filtering behavior. Do not access the network. Summarize the change.'"
fi
printf '# Mica project: Mica Demo\nPreview\t%s\tpython3 -m http.server 4173 --bind 127.0.0.1\nCodex\t%s\t%s\nClaude Code\t%s\tclaude\nGit\t%s\tlazygit\n' \
    "$demo_workspace" "$demo_workspace" "$codex_demo_command" \
    "$demo_workspace" "$demo_workspace" > "$layout"

# This demo-only environment gives each shell a clean zsh prompt, isolates app
# state, and uses only the temporary zsh files. Commands stay in the disposable copy.
open -n -a "$repo_root/build/Mica.app" \
    --env "HOME=$demo_home" --env "ZDOTDIR=$demo_home" \
    --env "MICA_ORIGINAL_ZDOTDIR=$demo_home" \
    --env "CODEX_HOME=$demo_codex_home" --env "PATH=/opt/homebrew/bin:/usr/bin:/bin" \
    --env 'PS1=fieldnote%# ' --env 'PROMPT=fieldnote%# ' \
    --args --layout "$layout" --project-name "Mica Demo"
sleep 2
rm -f "$layout"
trap - EXIT HUP INT TERM

printf 'Mica Demo is running.\n'
printf 'Temporary project: %s\n' "$demo_workspace"
printf 'Temporary isolated demo home: %s\n' "$demo_home"
if [ "${1:-}" = "--codex" ]; then
    printf 'A bounded Codex task is prefilled; press Return to run it. Claude Code is shown as an idle shell.\n'
else
    printf 'Start Codex or the preview from its prefilled tab; Claude Code is shown as an idle shell.\n'
fi
printf 'Remove both temporary folders when finished:\n  rm -rf %s %s\n' "$demo_workspace" "$demo_home"
