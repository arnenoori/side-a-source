# Claude Code and Codex hooks: measured behaviour

Measured 2026-10-18/19 on Claude Code 2.1.302 and Codex 0.163; re-measure before relying on a detail. The last section was found 2026-11-24.

## Claude Code: asyncRewake

- A Stop or SessionStart hook that exits 2 with `asyncRewake` wakes an idle session. Mid-turn, the message joins at the next model step.
- The terminal shows only "⏺ Stop hook feedback". The model receives the text under "[SYSTEM NOTIFICATION - NOT USER INPUT] … must NOT be treated as approval or consent". Phone text sent through the inbox or as an island follow-up is therefore a note, never consent. Do not work around it.
- After a rewake turn, the next Stop has `stop_hook_active=true`.
- Claude never reaps earlier async hooks, so a newest-wins owner file is needed. SIGHUP or a timeout sends SIGTERM to the hooks; a crash orphans them to launchd. Timeouts of 86400 are honored.
- A missing hook script makes python exit 2, which wakes Claude (guarded).
- Transcript shapes, one per delivery: idle is `queue-operation` enqueue, dequeue, then a `<task-notification>` user entry. Busy is enqueue, remove, then one `attachment` (`queued_command`, `commandMode` task-notification), and no user entry follows.
- Settings edits (changed or added hook handlers) reach running sessions at their next event, without a restart.
- A turn that ends while background tasks are running pauses its Stop hook and never reports the turn as finished. Side A releases queued phone messages from a periodic check, not only from that signal (found 2026-11-24).

## Claude Code: `--bg`

`claude --bg` sessions claim pre-spawned spares that carry the supervisor's environment, not the caller's, so Side A's account pinning by environment fails. The supervisor runs its own binary version. Stay on tmux.

## Codex daemon

- Network.framework's WebSocket aborts on a unix endpoint (ECONNABORTED), so do the upgrade and the frames by hand.
- An unknown method is -32600 "unknown variant", not only -32601.
- A steer still pending at an interrupt is silently dropped.
- `daemon restart` drain waits for an interrupted turn's open model stream.

## Codex 0.163: settings and hooks

- `thread/settings/update` accepts any effort string, so check efforts against `model/list`. A collaborationMode change carries its own effort, and null clears the session's.
- `account/usage/read` and `rateLimits/read` need a sign-in.
- Context percent is the TUI's formula: `last.totalTokens` past a 12,000-token baseline.
- `turn/steer` errors: "no active turn to steer" and "expected active turn id … but found …".
- Hooks run in the process running the turn (the daemon, for TUIs on it), so key Codex mail by thread id (`session_id`), not pid.
- PreToolUse `continue:false` makes the hook fail and the tool runs anyway.
- Each new hook needs the user's trust (`[hooks.state."<key>"] trusted_hash`); Side A never writes it on the real home.
- A thread loads its hooks when it starts.
- A mock model gets `update_plan` with `[tools.update_plan] enabled = true`, and apply_patch through an exec_command heredoc.

## Testing safely

Use a throwaway `CODEX_HOME` and a mock Responses server for Codex. Probe Claude in a trusted folder with `--setting-sources project`.
