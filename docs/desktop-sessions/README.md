# Sessions on the Mac (PRD set)

Status: proposal, 2026-11-25, tree at **cb60816**. Seven documents. This page says what was found, what is proposed,
in what order, and what the owner has to decide. The cross-check with Codex is in
[section 5](#5-cross-check-with-codex).

## 1. What was found

**The Mac and the phone share almost nothing in sessions.** The phone's session work went into `apps/ios` and
`SideARemoteKit`. `Sources/SideA` imports neither the kit nor the phone's views; it reads a cut-down transcript
format from the bridge (tools flattened to strings, thinking dropped) into its own model types. So every phone
improvement that needs a field the Mac format lacks could not be ported, and was not.

**The Mac is missing, compared with the phone:** tool status and output, inline diffs in history, images,
subagents, thinking, turn folding, streaming, todo lists, `@file` mentions, the queue list, steer-or-queue, a
composer on past sessions, snooze, pull-request state on rows, hand off to the other agent, a starting state for a
new session, the trust prompt, and remembered New Session choices. The full table is in each PRD.

**Starting a session feels slow, and may be slow.** It feels slow because the Mac shows a blocked sheet and then
nothing until its next check finds the session; the phone shows a starting row and a starting view. Whether the
underlying time can be cut is not known: reading the code found candidates (two lists the sheet waits on, a login
shell, a first check that usually lands before the agent has registered) and no measurements. The first is fixed
by design; the second is measured before anything is changed.

**Other desktop agent apps** were read for ideas: T3 Code's documentation and source, and the public
documentation of cmux, the Codex app, Conductor, Zed and Paradev. What recurs across them: start is optimistic and
one keystroke; the sidebar answers "what needs me" first and can be driven from the keyboard (`⌘1–9`, next needing
attention, a `⌘K` switcher that searches content); new sessions inherit the last choices; follow-ups queue or
steer with a key each and the queue is visible. That survey is outside this repository and is not re-verified
here.

## 2. The documents

| # | Document | In one line |
| --- | --- | --- |
| 1 | [One session kit](01-shared-session-kit.md) | A shared target for session logic and views; the Mac reads wire types in process |
| 2 | [Fast start](02-fast-start.md) | Optimistic start on the Mac, then the real time out of the path |
| 3 | [Transcript](03-transcript.md) | The phone's transcript on the Mac, appended to instead of re-read |
| 4 | [Composer](04-composer.md) | Mentions, queue, steer, a composer on past sessions, persisted drafts |
| 5 | [Sidebar and navigation](05-sidebar-and-navigation.md) | Attention-first sections, a Session menu, `⌘1–9`, `⌘⌥A`, `⌘K` |
| 6 | [New Session](06-new-session.md) | Prompt first, remembered picks, a key per choice, any folder, fan-out |
| 7 | [Settle, rewind, resume at reset](07-settle-rewind-resume.md) | Three ideas with no start in the tree; after the rest |

## 3. Order

**Tranche A: small, no shared kit, felt at once.**

1. Composer focus no longer steals from search and find (PRD 4 phase 0).
2. Session menu and shortcuts over today's list; Player menu disabled in this window; toast; resizable sidebar
   (PRD 5 phase 1).
3. New Session remembers its choices and its lists fill independently (PRD 6 phase 0).
4. Measurement of the start path (PRD 2 phase 0).

**Tranche B: the start.**

5. Store-owned launches: the sheet closes at once, a starting row and pane, trust and failure on the Mac, auto-open
   (PRD 2 phase 1). Watcher and predicate fixes, tmux pre-start (PRD 2 phase 2, first half).
6. The prompt-first sheet with chips, each with its adapter fix (PRD 6 phase 1).

**Tranche C: the kit and the transcript.**

7. Extract and move the logic (PRD 1 phase 1).
8. Local transcript subscription; the Mac reads wire transcripts; lineage reply (PRD 1 phase 2).
9. Views into the kit as the transcript phases need them (PRD 1 phase 3 with PRD 3 phases 1 to 4).

**Tranche D: on top of the kit.**

10. Composer: mentions, drafts, recall; then local receipts, queue, delivery keys, outgoing bubble; then a composer
    on past sessions (PRD 4 phases 1 to 4).
11. Sidebar sections, shared row facts and menus, switcher, snooze, undo, multi-select (PRD 5 phases 2 to 4).
12. Background start, terminal default, base branch, restart chips, fan-out (PRD 2 phase 3, PRD 6 phases 2 to 4).
13. PRD 7.

Each numbered item is one branch and one pull request through `scripts/check.sh` and `scripts/merge-pr.sh`. An
item a Mac user would notice adds its sentences to `CHANGELOG.md` under Unreleased.

### What is built

On the branch `feat/desktop-sessions`, as of 2026-11-26. Everything here builds and passes its tests and lint. The
logic is unit tested; the views were written without a way to drive the window, so each wants a pass in `--demo`
and on a real session.

| Order item | State |
| --- | --- |
| 1. Composer focus | Built. |
| 2. Session menu, shortcuts, sidebar, toast | Built, with `⌘K` and `⌥⌘S`. The list's own `⌘⌫` and `Space` are not, and `⌘Z` is a menu item without a key (a menu key would take `⌘Z` from the message field). |
| 3. New Session remembers; lists fill independently | Built. |
| 4. Measurement | Built: `took: start launcher` and `took: start listed`, read by `scripts/perf-summary.py`. In-pane shell timing is not. No numbers have been collected. |
| 5. Store-owned launches | Built, with the watcher fix and the tmux pre-start. |
| 6. Prompt-first sheet with chips | Built: chips and their keys (a key steps to the next choice; it does not open the menu), Choose… and folder drop, mode with a confirmation for the ones that lift checks, pasted photos, worktree base branch. The prompt has no `/` or `@` completion yet. |
| 7. Logic into the kit | Partly. Moved: command suggestions and highlighting, mention parsing and dropped paths, streaming boundaries, the transcript layout, turn folding, tool labels, session search, snooze choices, the settle rule. Not yet: the Markdown parser, `SessionPhase` and grouping, delivery choices, the reply state machines. |
| 8. Mac reads wire transcripts | Partly. The window reads `show --format remote` and draws from the shared layout; it is refreshed when the old view's data changes, not by its own subscription, and the old reader still runs beside it. Find, search-hit pages and lineage are still the old view. |
| 9. Views into the kit | Not started. The Mac's step, diff and fold views are its own. |
| 10. Composer | Built: persisted drafts, continue-by-typing, `@` mentions, prompt recall, the queue list with reword and Send Now, `⌘↩`, outgoing messages, files dropped by path. Not built: local operation ids (a Mac send still has no idempotency key, and an outgoing message is matched to its echo by its words), typed answers to a request, the model chip in the composer row, the long-paste file. |
| 11. Sidebar | Built: snooze with a local observer, undo, the waiting quit, multi-select, Resume and menus on every row kind. Sections still come from the Mac's own lists, not a shared `SessionPhase`; the shared action descriptors and pull-request state on rows are not built. |
| 12. Switcher | Built. Full-text search is offered as an entry that hands the words to the search field. |
| 13. Fan-out, restart chips | Built: Claude and Codex together from one prompt; Restart Fresh picks the agent and model, and the same-agent restart now passes effort, mode and message. |
| From T3 Code, after the PRDs | Built: the Changes sheet's four sources (turn, uncommitted, branch, commits) read with the system Git; comments on diff lines gathered into one message; the prompt stash (`⌘S`, text only, attachments stay with their conversation); project actions from `side-a.json` or `package.json`, run in a terminal tab. Not built: reverting files with a conversation, a suggested next prompt, side chats. |
| PRD 7 | Settle is built (by age; a past conversation's pull-request state isn't read). Rewind is built for Claude as Edit from Here: Claude Code 2.1.332 takes `--resume-session-at` but ignores it in an interactive session, so the bridge files a copy that ends before the message (`sessions cut`) and resumes that, which was checked against the real CLI. Files are not reverted, and Codex has no way to resume part of a conversation outside its app server. Resume at reset: Autopilot already sent Claude sessions on when a limit lifted; the row now says Limited and when it continues, one session can be held back, and Codex sessions are detected from the turn's error and sent on the same way. The phone has no control for holding a session back. |

## 4. Decisions for the owner

1. **Terminal tab on start.** Proposed: off by default once the transcript and composer land, a remembered choice
   in the sheet. (PRD 2, 3.7)
2. **Pre-warmed pane.** Not proposed; `hosting.md` chose a fresh login shell. Decide after phase 0 shows how much
   of the wait is the shell. (PRD 2, 3.6)
3. **Shortcuts.** The table in PRD 5 section 3 is a proposal; `⌘T` for Show in Terminal replaces today's `⌘↩`,
   which the composer needs.
4. **Fan-out.** One prompt to Claude and Codex in two worktrees. Proposed as PRD 6's last phase.
5. **macOS 14.** Shared views fall back to plain materials below macOS 26. Raising the Mac's floor would remove the
   fallbacks; not proposed.

## 5. Cross-check with Codex

Codex 0.169.1 read the first six documents against the tree at cb60816, read-only, and returned 24 findings. All
were accepted. What they changed:

- **The launcher's global lock stays** (PRD 2, 3.5). The draft narrowed it to naming. It is what makes a retried
  start and a concurrent resume return one session, and tests pin that.
- **A start is its own object** (PRD 2, 3.1). The draft keyed the starting row by hosted name. That name is chosen
  inside the launcher, and everything on the Mac is keyed by conversation id, so the row had no identity at the
  moment it was needed.
- **Both account-selection calls in the pane stay** (PRD 2, 3.6). The draft removed the second as redundant; it is
  deliberate, and the pane runs one login shell, not two.
- **The latency trace is candidates, not conclusions** (PRD 2 section 1, README section 1). Several claims were
  overstated: there are two bridge processes plus the indexer, git metadata has its own 30 s cache, and a registry
  change is refreshed ahead of the index spacing.
- **The logic does not move "as is"** (PRD 1 section 3). It names types nested in the phone's stores and relies on
  the app's default actor isolation; each piece now has its extraction listed.
- **The phone's extensions use what moves** (PRD 1 section 2). The shared framework, the notification extension and
  the widgets are in the target plan.
- **The Mac's host records stay** (PRD 1, position 5). `LiveSession` holds the process identity Quit rechecks;
  only the second transcript model goes.
- **There is no local transcript subscription yet** (PRD 1 phase 2, PRD 3 section 2). It is built at Remote start
  and speaks to sockets; splitting it is now an explicit step, and "append only" became "stable identity and a
  kept anchor".
- **The host seam was too thin** (PRD 1 section 4): now a context with destinations, answers and queue actions.
- **Outgoing bubbles need local receipts first** (PRD 4): Mac sends carry no idempotency key and admission marks
  are read through Remote.
- **"Any file" attachments were not parity** (PRD 4, PRD 6): uploads are image-only end to end. Replaced by
  inserting the file's path.
- **Several proposed chips would have done nothing** (PRD 6 section 1): the Mac's start path drops attachments,
  mode and base branch. Each chip now ships with its adapter fix.
- **Keyboard** (PRD 5 section 3): a precedence table, standard editing keys preserved, and the discovery that the
  Player menu's `⌘←`, `⌘→` and `⌘↩` are live in the Sessions window.
- **Sections and undo are Mac policy, not the phone's** (PRD 5 section 2): said so, with busy-quit confirmation
  kept.
- **Order** (section 3 above): a smaller first tranche, and the kit's view phase scheduled where the transcript
  needs it.
- About two dozen wrong line references and signatures, corrected in place.

Checked and found correct: an Apple-only kit target is feasible with `SideARemoteKit` importing it; the Mac list
shows only live rows with a conversation id; the quoted timeouts (45 s launcher, 30 s lock, 20 s model list, 600 s
model cache, 120 s grace); the 6,000-character cut and the diff preview limits; the focus-stealing code, the fixed
sidebar, the removed commands and the reversed find order.

PRD 7 was written after the review and has not been cross-checked.
