# Security

Mica runs interactive shells and, only when you start dictation, uses the microphone. Speech recognition runs locally after the first model download.

## Reporting a vulnerability

Please report security issues privately through GitHub's "Report a vulnerability" option on the repository's Security tab rather than a public issue. Include the macOS version, steps to reproduce, and the impact you observed.

## Scope notes

- Terminal output is untrusted. Mica only opens `http` and `https` OSC 8 links, and only on Command-click.
- Tests use local fixtures and never send prompts to agent CLIs or make network calls.
