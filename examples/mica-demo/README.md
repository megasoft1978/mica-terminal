# Mica demo fixture

This fictional Fieldnote board exists only to create a safe Mica demo. It has no connection to a real project, account, or service. `scripts/launch-demo.sh` copies it to a fresh temporary folder each time, initializes a local Git repository, and opens Mica with Preview, Codex, Git, and Shell tabs. It never edits user shell or agent configuration.

For a Codex demo, start the Codex tab and ask it to implement the sample filter behavior. The command uses Codex's `workspace-write` sandbox rooted at the temporary copy. To discard the demo, close Mica and remove the printed temporary folder.
