# First use and recovery

Side A needs Python 3.9+ to run its local session supervisor, and the selected agent’s official command-line app. Setup shows install links only when a tool is missing or incompatible. Returning to Side A checks again. Installed tools collapse to one readiness line during account setup; versions remain in Settings.

Sign in through the provider, then return to Side A. Verification runs automatically after the sign-in button was used; Verify remains available if a callback or focus change was missed. A positive signed-out result clears readiness. A temporary CLI failure or timeout preserves the last verified state and never triggers a handoff on its own. Every actual session launch still verifies the account again.

After Done, PLAY glows until a managed session starts. An unconnected selected account highlights OPEN. Reduce Motion uses a steady highlight. The first run of the provider’s terminal interface may still require its own setup and project trust prompts.

Recovery is limited to observable cases. A queued handoff says “WAITING FOR TURN / INPUT”; finish the turn and submit or clear your draft in Terminal. The menu exposes Open Terminal for pending, limited, or error states. It does not discard input, replay a prompt, or force a process handoff.

Settings and Help offer Save diagnostics. The local JSON contains a schema version, app and macOS versions, architecture, Python/Claude/Codex tool state and version, a fixed session-state enum, and whether the library loaded. It excludes account details, paths, IDs, transcripts, raw errors, logs, and credentials. The file is created with mode 0600, and Side A never uploads it. Review it before sharing through your chosen support channel.
