# SSH connection profiles

## Goal

Make a saved remote destination feel like a first-class Mica terminal tab: choose a profile, connect through the system OpenSSH client, and start in the requested remote folder. Connections remain ordinary interactive PTYs, so shells, editors, Claude Code, Codex and other terminal programs work as they do in a local tab.

This feature does not create a VPN, implement SSH, store private keys, alter SSH host-key policy, or make a remote desktop connection. It uses network routes already available to macOS (LAN, VPN, Tailscale, or another overlay) and OpenSSH configuration/authentication already configured by the user.

## User experience

1. **Session → SSH Connections…** opens a native profile manager. Profiles have a friendly name, an OpenSSH destination, and an optional remote starting folder. The destination may be a `Host` alias from `~/.ssh/config`, `user@host`, or a host/IP. Saving and editing do not initiate a network connection.
2. Each saved profile can be opened in a new Mica tab. Mica opens a PTY-backed `ssh -tt` session and requests an interactive remote login shell in the chosen folder. The profile name appears in the tab; the active remote directory is reported by the remote shell when supported, with a useful profile-name fallback.
3. Profiles are available from the Session menu and restored project layouts can reference a profile by stable ID. Restore opens a fresh connection, never resurrects an old network process or terminal contents.
4. Failed connections remain visible in the PTY as OpenSSH diagnostics, with ordinary Retry/reconnect behavior left to the user. No background probes or automatic retries.
5. A separate optional action may open a saved host in RustDesk when installed. RustDesk stays an external graphical-control app; its credentials, configuration and trust prompts remain there.

## Scope and data model

### First release

- Per-user profile records: stable UUID, display name, destination, remote directory.
- A destination accepts a conservative OpenSSH host token or `user@host`; advanced options live in OpenSSH config, including `IdentityFile`, `IdentityAgent`, `ProxyJump`, `ProxyCommand`, `LocalForward`, and platform-specific VPN integration.
- Remote folder is passed as a safely quoted `cd` command; the remote interactive shell is then `exec`'d. The folder is a POSIX path on the remote machine. An empty folder uses the remote login shell's normal start directory.
- Never interpolate untrusted profile text into local shell syntax. Validate the destination before composing the command and quote the remote path for the remote POSIX shell, then quote that complete remote command as a local shell argument.
- Use `ssh -tt` to ensure full-screen programs receive a remote PTY. Do not disable host-key checking, forward the local agent, force password authentication, or add application-managed identities.
- Profiles contain no secrets. OpenSSH/ssh-agent/Keychain and the SSH server retain responsibility for authentication and trusted host keys.
- Persist profiles in Mica preferences with a schema version and bounded record count/field lengths. Keep active sessions and profile definitions distinct.
- Add the smallest project-layout extension needed to refer to a profile by UUID. Existing v1 `.mica` layouts continue loading unchanged; arbitrary startup commands keep their current semantics.

### Explicitly deferred

- SSH config parsing/editing, identity/key generation, password storage, VPN control, tunnels/port-forward UI, SFTP/file browsing, remote installation, server-side Mica helpers, and built-in remote desktop.
- Tailscale-specific APIs. Standard `ssh` works with Tailscale IPs/MagicDNS and configured ProxyCommand where applicable; Mica should not require or control the Tailscale app.
- RustDesk authentication or silent connection setup. First validate documented macOS invocation behavior and keep any handoff optional.

## Security and reliability

- Use the user's system `ssh`; never implement the SSH protocol or parse private key material.
- Preserve OpenSSH's normal host-key prompts and `known_hosts` protections. A changed host key must remain a visible hard failure requiring user action.
- Do not set `ForwardAgent`; OpenSSH documents that a remote user able to access the forwarded agent socket can ask it to authenticate with the user's identities.
- Do not persist passwords, passphrases, key bytes, agent socket paths, or copied private SSH configuration in Mica profile data.
- Accept profile display strings as untrusted input. Enforce bounded lengths, reject control characters/newlines and invalid destinations, and quote remote paths using a tested routine. Add adversarial tests for quotes, whitespace, Unicode, leading dashes, shell substitutions, and newlines.
- OpenSSH handles VPN routing externally. Explain that a same-LAN SSH connection should work with Remote Login enabled, while remote access through default Starlink IPv4 CGNAT needs a VPN/overlay, reachable IPv6, or an eligible public-IP route.
- Limit the number of profiles and restored connections. No automatic parallel connection storm at launch; restore follows existing per-window tab limits and starts only saved profile tabs.

## Implementation sequence and commits

1. **`feat: add secure SSH profile model`** — isolated profile validation, stable IDs, normalization and command-construction helpers with unit tests. No UI and no network access in tests.
2. **`feat: manage SSH connection profiles`** — native AppKit profile manager, validation/errors/accessibility, versioned preferences, Session-menu entry points. Test CRUD, malformed settings data, validation, window/menu routing and multiple windows.
3. **`feat: open SSH profiles in terminal tabs`** — PTY launch through OpenSSH, remote working directory behavior, command/status/tab labels, close/quit cleanup. Use a local fake `ssh` executable in the PTY harness to verify argv/quoting and interaction; tests must never contact an SSH server.
4. **`feat: restore SSH project tabs`** — versioned `.mica` profile references, backwards compatibility and bounded restoration. Add local fixture layouts and launcher/restore tests.
5. **`feat: add optional RustDesk handoff`** (only if macOS launch invocation proves reliable) — open the installed app for a selected saved destination with explicit user action; no credentials in arguments and no dependency when RustDesk is absent.

Keep each numbered item a separate reviewable commit. Do not combine a RustDesk handoff with SSH session management.

## Acceptance criteria

- A user can add, edit, remove, and connect to a profile using a native keyboard-accessible macOS UI.
- The connection uses the system OpenSSH binary and the normal user environment/configuration, keeps host-key verification intact, and never stores secrets in Mica.
- A profile starts in its remote folder, including paths containing spaces, apostrophes, Unicode and shell metacharacters, without executing injected commands.
- SSH behaves as a normal interactive terminal session: PTY dimensions resize, full-screen TUI programs work, terminal cleanup closes the child process, and closing the connection returns to the local Mica tab list.
- Saved profiles and layouts survive relaunch; a failed/offline host does not hang Mica or trigger automatic repeated connections.
- Existing local project tabs, Claude Code, Codex, arbitrary commands and interactive shell workflows remain unchanged.
- Build and full test suite run; PTY tests use only local fixtures. Because `src/mica_app.m` is touched, follow repository instructions to run `make sanitize` and `make stress` as well.
- RustDesk handoff is not shipped until it is verified on macOS without embedding a password or silently weakening its security prompts.

## Research references

- OpenSSH `ssh(1)`: PTY allocation with `-t`, interactive shell behavior, host-key checking and SSH exit behavior: <https://man.openbsd.org/ssh>
- OpenSSH `ssh_config(5)`: host aliases, identity selection, agents, jump hosts and the warning that agent forwarding grants remote access to agent operations: <https://man.openbsd.org/ssh_config>
- Apple Remote Login: enabling SSH/SFTP access on a Mac and limiting allowed users: <https://support.apple.com/guide/mac-help/mchlp1066/mac>
- Apple OpenSSH/Keychain notes (`UseKeychain`, `AddKeysToAgent`): <https://developer.apple.com/library/archive/technotes/tn2449/_index.html>
- Tailscale SSH: normal OpenSSH remains usable; `tailscale ssh` availability differs on sandboxed macOS builds: <https://tailscale.com/kb/1193/tailscale-ssh> and <https://tailscale.com/docs/reference/tailscale-cli?tab=macos>
- Starlink IP policies: default IPv4 uses CGNAT and blocks inbound IPv4; public IPv4 availability depends on service plan: <https://starlink.com/lv/support/article/1192f3ef-2a17-31d9-261a-a59d215629f4>
- RustDesk supported clients and setup: <https://rustdesk.com/docs/en/client/>. CLI connection behavior has community reports, but the standard client page does not establish a stable, documented macOS connection-handoff contract; keep it deferred pending an on-device check.
