# Claude Code and Codex notifications

Mica handles terminal BEL, OSC 9, and OSC 777 notifications from terminal applications and agent hooks. Notifications from background tabs show an `!` marker; macOS Dock attention is requested while Mica is unfocused. Selecting a marked tab clears its marker. Focus gained/lost events are also passed to the active terminal session.

Claude Code and Codex run as regular commands inside zsh tabs. A command in a `.mica` layout is placed at the prompt; press Return to start it. Mica also reads OSC window titles from terminal programs and adds them to the tab label. Commands started with Mica's `--command` option report their exit status; completed background commands get a tab indicator, and Mica requests Dock attention while unfocused.

Codex supports `tui.notifications`, `tui.notification_method` (`auto`, `osc9`, or `bel`), and `tui.notification_condition` (`unfocused` or `always`). Mica identifies itself as `TERM_PROGRAM=Mica`, so Codex may choose BEL when automatic terminal detection does not recognize OSC 9. Mica handles either method. See the [Codex configuration reference](https://developers.openai.com/codex/config-reference#tui-notification-settings). Leave your current Codex configuration alone unless you want to turn notifications on or change their focus condition.

Claude Code does not need a hook to run in Mica. If you want Claude's permission and completion events to mark tabs, add a `Notification` hook to the Claude Code settings file you use. The helper requires `jq` and emits the OSC 777 `terminalSequence` supported by Claude Code:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|agent_needs_input|agent_completed",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/mica-terminal/scripts/claude-notify.sh"
          }
        ]
      }
    ]
  }
}
```

Replace the helper path with the location of this checkout. Merge the hook into your existing settings instead of replacing the file. Keep the helper executable (`chmod +x scripts/claude-notify.sh`). Claude Code documents this `terminalSequence` hook interface and the supported OSC/BEL allowlist in its [Hooks reference](https://code.claude.com/docs/en/hooks#emit-terminal-notifications).
