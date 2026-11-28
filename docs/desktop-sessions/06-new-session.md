# The New Session flow on the Mac (PRD 6)

Status: proposal. Facts taken at **cb60816**. How fast it starts is [PRD 2](02-fast-start.md); this is what you
choose and how few choices it takes. Index in [README.md](README.md).

## Recommendation

`⌘N`, type, `↩`. Everything else is already what you chose last time and is one keystroke away. The sheet becomes
the phone's New Session (a prompt with a row of chips) with keys for each chip, and gains what `StartHosted` already
carries and the Mac form does not offer.

## 1. Today

A form (`Sources/SideA/NewSessionSheet.swift:30-60`): Agent, Folder, Model, Effort, Account, "In a new worktree",
First prompt. Nothing is remembered between uses: the folder is the first project, the agent the first installed.
There is no way to pick a folder that is not in the recent list, no permission mode, no attachments and no worktree
base branch. Account and worktree are hidden when hosting is off, with a footer of explanation.

The wire type has more than the form (`StartHosted.permissionMode`, `.attachments`; `RemoteProject.branches`), but
**the Mac's own path drops some of it**, so a chip added today would do nothing:

- `SessionStore.start` never resolves attachment ids into image paths before `commands.start`
  (`SessionStore.swift:1040`, `SessionCommands+Actions.swift:63-76`).
- The no-hosting fallback types `claude` or `codex` into a tab with model, effort and prompt only
  (`SessionStore.swift:1025-1035`): no mode, no attachments.
- `StartHosted.worktree` is a `Bool`, and `SessionCommands.start` turns it into `"HEAD"` (`:74`), though the
  launcher takes any base (`HostedSessions.swift:224`).
- A same-agent Restart Fresh builds its start without the requested effort, mode or message (`:134-144`).

Each chip below ships with the adapter fix and a test that the value reaches the launcher.

The phone's sheet (`apps/ios/SideARemote/Features/NewSession/NewSessionSheet.swift`) leads with the prompt, shows
recent folders as chips, remembers the picks per Mac, and keeps a discarded draft for undo.

## 2. The sheet

```
  What should we build in side-a?
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  (prompt, focused, grows to 8 lines)                     │
  │                                                          │
  └──────────────────────────────────────────────────────────┘
  [side-a ▾] [Claude ▾] [Opus · high ▾] [Worktree] [Autopilot ▾] [Ask ▾]     [Start ↩]
```

- The prompt has focus when the sheet opens. It is the Mac `ComposerField`: `/` and `$` suggestions and pasted or
  dropped images work in phase 1 (the Mac has them today); `@` mentions and file drops arrive with
  [PRD 4](04-composer.md).
- **Remembered.** Folder, agent, model, effort, mode, worktree and account are the last ones used. Model, effort
  and mode are remembered per agent; the agent and the worktree choice per folder. Stored with the Mac's other
  session preferences.
- **Opened from a session**, the sheet starts in that session's folder.
- **Chips and keys.** Each chip opens a small menu and has a key that works while the prompt has focus:

| Key | Chip |
| --- | --- |
| `⌘O` | Folder: recent projects, type to filter, and **Choose…** (`NSOpenPanel`) for any folder |
| `⌘⇧A` | Agent: Claude or Codex; greyed with "Not installed" when missing |
| `⌘⇧M` | Model |
| `⌘⇧E` | Effort |
| `⌘⇧B` | Worktree on or off; when on, a base branch menu from `RemoteProject.branches`, defaulting to the current branch |
| `⌘⇧U` | Account: Autopilot's pick, or a ready account with its 5-hour usage |
| `⌘⇧Y` | Mode: the session's permission mode. A mode that lifts checks asks for confirmation once |

The sheet is modal, so its keys are its own; none is one the Session menu uses for something else except `⌘⇧A`
(Archive there), and none is a standard editing or window key.

- **Start.** `↩` starts and opens the session. `⌘↩` starts in the background and keeps the sheet for the next
  one ([PRD 2](02-fast-start.md)). `⇧↩` is a newline. An empty prompt starts an idle session, as today.
- **Draft.** Closing the sheet with text keeps it; `⌘N` brings it back. `Esc` on an empty sheet closes.
- **Without hosting**, Worktree, Account and Mode are shown disabled with the one reason on hover, attachments are
  not accepted, and the footer goes. The fallback is not taught new flags.

### Fan-out

Holding `⇧` while choosing a second agent or model in its menu adds it instead of replacing it. Start then creates
one session per choice, each in its own worktree, from the one prompt. The chips show "Claude + Codex". T3 Code has this, and Side A is well placed
for it, since it already hosts both CLIs and makes worktrees. It needs hosting and a git folder. Each child is its
own launch ([PRD 2](02-fast-start.md) 3.1) with its own retry key, so one can fail and be retried while the other
runs.

### Templates

Not proposed. Slash commands and skills already are the user's templates, and they complete in the prompt field.

## 3. Other ways to start

- **From history**: Resume and Fork on a past row and in its viewer start hosted with the same optimistic row.
  A past session's composer resumes by typing ([PRD 4](04-composer.md)).
- **From a pull request**: later. Pull-request collection does not read the head branch or repository
  (`Sources/SideA/Remote/PullRequests.swift:51`), and a fork's head is not in the local repository at all, so this
  needs head resolution and a fetch before it is a menu item. From an issue URL likewise.
- **From the menu bar**: the popover's footer gets New Session beside Sessions, opening the window with the sheet.
- **Dropping a folder** on the Sessions window opens the sheet in that folder.

## 4. Restart Fresh and Hand Off

`RestartSheet` on the Mac has only the editable handoff text. `RestartRequest` carries agent, account, model,
effort, mode, message and attachments, and the phone offers them. The Mac's sheet gets the same chip row as New
Session. Handing off to the other agent is already implemented on the Mac side
(`SessionCommands+Handoff.swift`) and only lacks Mac UI. The same-agent path needs the adapter fix in section 1
first.

## 5. Phases

0. Remembered picks in today's form, and lists that fill in independently. Ships in the first tranche.
1. Prompt-first sheet with chips, keys, Choose…, draft kept; mode and image attachments with their adapter fixes.
2. Worktree base branch (a local parameter; a wire field only if the phone wants it); start from history rows;
   folder drop; menu-bar entry.
3. Restart Fresh and Hand Off on the chip row.
4. Fan-out.

## 6. Proof

- Remembered picks: start once, reopen, the same choices are selected; per-agent model is restored when the agent
  changes back.
- A folder outside the recent list starts a session there (fake agent).
- Each key opens its chip with the prompt still holding its text.
- Mode and an image reach the launcher's arguments (fake launcher records them).
- Fan-out with the two fake agents creates two hosted sessions in two worktrees from one Start; with one launcher
  failing, the other still starts and the failed one retries without a duplicate.
- `--demo` shows the sheet with made-up projects and never writes outside its temporary folder.

## 7. Risks

- **Any folder** means a folder the agent has not been trusted in. The trust card from PRD 2 answers it for
  Claude; for Codex the card points at the terminal.
- **Fan-out doubles spend** by design. The Start button says "Start 2".
