# Settling, rewinding and resuming at reset (PRD 7)

Status: proposal, the least settled of the set. Facts taken at **cb60816**. These are the three ideas from T3 Code
that Side A has no half-built version of. Each stands alone and each comes after PRDs 1 to 6. Index in
[README.md](README.md).

## 1. Settle

### Problem

History is every conversation ever, by project. A conversation that ended an hour ago and one from August look the
same. Archive exists but is manual and hides the conversation from search results by default.

### Proposal

A finished conversation is **settled** when it stops being current, without the user filing it:

- seven days with no new message, or
- its pull request merged or closed (`RemoteSession.pullRequest`, already read for the row badge).

Settled conversations leave the main list and stay in search and in the `⌘K` switcher. A new message, a resume or
a fork un-settles one. The list gains a **Recent** section in place of the per-project history as the default, with
the by-project view one click away; settled ones are under "Earlier", folded.

Settled is derived, not stored, so there is nothing to migrate and nothing to sync: it is a function of the last
message time, the pull-request state and the pin. Pinned conversations never settle. Archive keeps its meaning
(hidden unless asked for).

The phone gets the same rule from the kit, so the two lists agree.

### Proof

The rule is one pure function with a table test: age, pull-request state, pinned, running.

## 2. Rewind: edit from here

### Problem

The Mac has "Edit & Resend" on a user message, which copies the text into the composer; the conversation keeps
everything after it. Fork exists for Claude and forks from the end. The phone has "Fork from Here" on the latest
reply only.

### Proposal

On any user message: **Edit from Here**. It starts a fork of the conversation that ends just before that message,
with the message's text in the composer, ready to change and send. The original conversation is untouched and the
fork shows in the lineage row, as forks do today.

- Claude: needs resuming a conversation at a given message. **(verify)** that the installed Claude Code can resume
  at a message id; if it cannot, the fork is made by Side A writing a truncated copy of the transcript under a new
  id, which is how the bridge's fork lineage is already tracked.
- Codex: cannot fork from the Mac today (`!session.isCodex`, `SessionViewer.swift:94`). **(verify)** `codex fork`
  or resume-at support in 0.169; until then the item is Claude only.

**Reverting the files too** is not proposed. T3 Code does it with hidden Git refs taken at every turn, only for a
worktree no other thread shares, and refuses when the provider cannot roll back. Side A takes no per-turn
checkpoints, and adding them means writing to the user's repository on every turn. What Side A can offer honestly:
when the fork is started in a new worktree, the sheet offers the base "as it was before this message" only if the
turn's diff is known (`turns/{turn}/diff`) and applies cleanly in reverse. Otherwise it says the files are as they
are now. Later, and only if asked for.

## 3. Resume at reset

### Problem

When every account an agent could use is at its limit, the session stops with a limit message. Autopilot trades
logins when another account has room; when none does, the session waits for the user to notice the reset.

### Proposal

A session stopped by a usage limit shows **Limited** as its state, with the reset time from the usage Side A
already reads (`AccountUsage` windows), and one choice: **Continue at reset**. Chosen, Side A sends "continue" to
that session when the window resets (or when Autopilot finds an account with room, whichever is first), and the row
shows "Continues at 3:40 pm". The choice can be made the default in Settings.

- Detection is the failure the wire already carries (`SessionFailure`) for a limit **(verify the kind and that it
  is distinguishable from other failures for both agents)**.
- Sending is the existing reply path. The Mac must be awake at the reset; Keep Awake is offered when it is not on.
- The phone shows the same state and choice from the same wire fields: one new optional field on the session,
  `resumesAt`, behind a capability.

### Proof

A fake agent that prints the limit failure; a clock injected into the scheduler; the reply is sent once at the
reset and not twice if Autopilot swaps first.

## 4. Order

Settle is small and comes with PRD 5 phase 2. Resume at reset comes after it and touches Autopilot, so it wants the
owner's eye on the design before it is built. Rewind waits on the two **(verify)** items.
