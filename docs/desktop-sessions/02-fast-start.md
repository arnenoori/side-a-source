# Starting and opening a session without waiting (PRD 2)

Status: proposal. Facts taken at **cb60816** by reading code; nothing below was timed on a running system, and
[phase 0](#phase-0-measure) exists because of that. Index in [README.md](README.md).

## Recommendation

Two things, in this order.

**Stop making the user watch the wait.** Pressing Start closes the sheet, puts a Starting row in the list, selects
it, and shows the prompt as sent. The phone has done this for months; the Mac shows a disabled "Starting…" button on
a blocked sheet, then nothing, until a row appears by itself some seconds later. Most of what feels slow is this.

**Then cut the real time**, where measurement says it is. Reading the code found candidates: a sheet that cannot be
used until two lists load, a new session the Mac only notices when its next check happens to land after the agent
has registered, and bridge processes that answer one request at a time. None of them is timed yet, so
[phase 0](#phase-0-measure) comes before any of that work.

## 1. Where the time goes

Traced from `NewSessionSheet.start()` to a usable session. Constants are quoted from the code.

### Before Start can be pressed

- The sheet awaits options and projects together but assigns options first (`NewSessionSheet.swift:94-95`), so the
  folder picker says "Loading…" until **both** finish, and Start is disabled while the folder is empty.
- Options spawns `codex debug models` (20 s timeout), cached 600 s in memory per Codex home
  (`Sources/SideA/Remote/RemoteRoutes+Setup.swift:127-137`): paid by whoever asks first after launch, which is the
  sheet unless a phone asked earlier.
- Projects runs `recent --days 60 --limit 500` on the reader process and then three `git` processes for each of up
  to 50 folders, 8 at a time (`RemoteRoutes+Hosted.swift:177-222`). The `recent` result has a 15 s cache keyed on
  `listGeneration`, which rises on every index pass that indexed anything, so that half is often cold while
  sessions write. The git half has its own 30 s cache (`:213`) and is not affected.

### After Start

1. The sheet stays up, button disabled, until the launcher returns (45 s timeout, `HostedSessions.swift:255`).
2. The launcher (`bridge/hosting.py:67-216`) runs serially: `tmux` server check (cold start if none; nothing
   pre-starts it), a **global** `flock -t 30`, a name (`git rev-parse`, `od`, `has-session`), for a worktree
   `git worktree add` **inside the lock**, then `new-session`.
3. The pane runs one `/bin/zsh -lic` (`hosting.py:185`): the user's whole `.zprofile` and `.zshrc`. Side A's
   `_side_a_select` runs twice in it, once from the `.zshrc` line and once from `launch.zsh` just before the agent,
   each with up to 1 s of `nc -z -G 1` when a remote pool file exists (`bridge/sidea_bridge.py:566,581`;
   `hosting.py:172`). Then the CLI's own startup and, for a new folder, its trust question.
4. The Mac opens a terminal tab (`osascript` for Ghostty and iTerm; Terminal.app runs another `zsh -lic`).
5. The Mac calls `refreshLive()` once, as the launcher returns (`SessionStore.swift:1044`). Nothing orders that
   after the CLI has written `~/.claude/sessions/<pid>.json`, and with a login shell and a CLI start in between it
   will usually be before. The row then needs FSEvents (0.25 s) plus a 300 ms debounce plus whatever pass is
   running, plus a `live` call that runs `ps` over every process and may run `lsof` for ports and, for Codex, for
   open rollouts (`bridge/sessions.py:2433-2451,2464-2488`). A registry change is refreshed ahead of the 2 s index
   spacing (`SessionStore.swift:376-381`).
6. A Codex session on a non-default account lives under `<root>/codex-conversations`, which is **not watched**
   (`SessionStore.swift:311`), and the refresh predicate only reacts to `/.codex/sessions/` or a conversation it
   already knows (`:385-389`). It appears on the 20 s loop.
7. The Mac never opens the new session. The user clicks the row when it shows up.

The trust question and the "screen has not changed for 20 s" signal are detected (`watchDialogs`,
`HostedSessions.swift:503-524`) and sent only to the phone (`RemoteController.swift:242`). On the Mac they are
visible only in the terminal tab.

### Opening and switching

- A cache hit is instant. A miss sends `show --limit 150` to the reader, which answers one request at a time and
  also serves phone transcript pages and the projects list.
- Every write to a session's file drops its cache entry (`SessionStore.swift:378,412-416`). So the sessions you
  switch between most, the busy ones, are the ones that miss.

## 2. What the user gets

### Start

1. `⌘N` opens the sheet with the last folder, agent, model and effort already chosen ([PRD 6](06-new-session.md)),
   from a list that is on screen at once from the last known projects and refreshed underneath.
2. Start (`↩`) closes the sheet in the same frame. A row titled from the first words of the prompt appears at the
   top of Working with a Starting state and is selected.
3. The detail pane shows the prompt as an outgoing bubble and "Starting". If the CLI asks to trust the folder, the
   card is there with **Trust and Start**. After 30 s without a session, **Show in Terminal** becomes the prominent
   button. Text typed into the field meanwhile is kept and is the session's draft when it is up. It is not sent
   for the user: the first prompt is still being delivered at that moment, and a second message racing it is the
   kind of surprise the draft avoids.
4. When the session's first row arrives, the pane becomes its transcript without a jump. No terminal tab is opened
   unless the user asked for one (section 3.7).
5. If the launcher fails, the row shows the error with **Try Again** and **Edit**, which reopens the sheet with
   that request. A newer draft in the sheet is never overwritten by a failed one.

This goes further than the phone, which waits for the Mac's answer before it leaves its sheet
(`apps/ios/SideARemote/Features/NewSession/NewSessionSheet.swift:476-484`) and whose 120 s grace hands the row back
to whatever the Mac reports, normally Idle, with no failure state. Closing before the launcher answers and showing
an error on the row are new behaviour, on the Mac first.

**Trust and Start** types the answer for Claude. Automatic trust refuses Codex
(`HostedSessions.swift:535-538`), so for Codex the card says what is being asked and offers Show in Terminal.

`⌘↩` in the sheet starts in the background: the session starts, the sheet clears and stays open for the next one,
and a line under the field says "Started · Open".

### Open and switch

Selecting a session that has been seen paints in the same frame, always, including a busy one. Selecting one that
has not shows the header and a placeholder at once and the page when it arrives.

## 3. Design

### 3.1 A launch the store owns

The hosted name is chosen inside the launcher (`bridge/hosting.py:163`), and everything on the Mac that belongs to a
conversation (the row, selection, the draft, attachments, the transcript cache) is keyed by conversation id
(`SessionStore.swift:29-38,219-227,914-921`). Neither exists when Start is pressed. So a start is its own object:

```swift
struct Launch: Identifiable {
    let id: UUID                 // made on the Mac at Start; the row's identity until the session is listed
    let request: StartHosted     // immutable snapshot, with attachments already resolved to paths
    let key: String              // the launcher's retry key, so Try Again cannot start a second session
    var hosted: String?          // set when the launcher returns
    var conversation: String?    // set when `live` lists it
    var state: State             // .launching, .booting, .attention(Attention), .failed(String)
    let at: Date
}
```

- `SessionStore` (in an extension file) holds `launches`. The list draws them at the top of Working. Selection
  gains a second case, a launch id, beside a conversation id.
- When `live` returns a session whose hosted name matches, the launch records the conversation id, selection moves
  to it in the same update, held text becomes the conversation's draft, and the launch is removed. Nothing else is migrated because
  nothing else was keyed by the launch.
- The task that awaits the launcher belongs to the store, not the sheet, so dismissing the sheet changes nothing
  about it. The resume and fork lock keeps its lifetime across the awaited launch (`HostedSessions.swift:211-264`).
- 120 s after the launcher returned with no conversation, the launch becomes `.failed` with Show in Terminal. The
  hosted session is left running; only the row's claim that it is starting ends.
- Whether a terminal tab is opened is the request's own flag (section 3.7), read when the launcher returns.

`HostedSessions.onAttention` has one listener today, Remote (`RemoteController.swift:242`). It becomes a list of
listeners so the Sessions window hears trust and stalled-screen signals with Remote off.

### 3.2 Notice the session when it exists

- While a launch is booting, `refreshLive` is retried for it until it is listed or the grace ends: every 500 ms
  for the first 20 s, when it is most likely to appear, then every 2 s. This is the existing call on a short timer for a bounded time, not a new
  probe: knowing which process owns which conversation is what `live` does, with `ps` and for Codex `lsof`, and a
  cheaper private check would have to reproduce it.
- `<root>/codex-conversations` is added to both watchers (`SessionStore.swift:311`,
  `Remote/TranscriptStream.swift:31`), **and** the refresh predicate at `SessionStore.swift:385-389` is widened to
  treat a new rollout there as it treats one under `/.codex/sessions/`.
- The 20 s loop and the other fallbacks stay.

### 3.3 `live` must not stall

There are two long-running bridge processes (list, search and `live` on one; transcripts on the other,
`SessionStore.swift:277-279`) and indexing runs in a third. `live` shares its process with `recent` and `search`,
and it can run `lsof` twice: for listening ports and, for Codex, for open rollouts. If phase 0 shows `live` waiting
or slow, ports are computed off the reply path and `live` returns the last known set; the Codex rollout check stays
on the path because it decides which rows exist.

### 3.4 The sheet is usable at once

- Projects and options are assigned independently, each as it arrives.
- The last projects list and the last options are kept on disk (in the existing `runtime` folder beside
  `sessions-snapshot.json`) and shown immediately; the fetch refreshes them in place.
- The projects cache is keyed on the set of folders, not on `listGeneration`.
- The Codex model list is cached on disk keyed by the Codex version string.
- Both are warmed when the Sessions window opens, not when `⌘N` is pressed.
- The phone's `POST /v1/hosted` checks the folder against the cached list and recomputes only on a miss
  (`RemoteRoutes+Hosted.swift:32`).

### 3.5 The launcher

- The tmux server is started when hosting is installed and when the app launches with hosting on
  (`hosting.py:294`), so the first start of the day does not pay for it.
- **The global lock stays as it is.** It is what makes a retried start and a concurrent resume return one session:
  it covers the key lookup, the name, the worktree, writing the key and `new-session` (`hosting.py:98-104,152-193`,
  pinned by `bridge/tests/test_hosting.py:132-168`). Narrowing it needs reservations with committed and failed
  states and is not proposed.
- Serving `codex-env` from the long-running bridge would save a Python start and a Keychain read for a picked Codex
  account, but the serve loop only parses session commands (`bridge/sidea_bridge.py:2489-2502`), so it is a new
  dispatch contract. Only if phase 0 shows it matters.

### 3.6 The pane's shell

No change proposed. `_side_a_select` runs from the `.zshrc` line and again from `launch.zsh`; the second call is
deliberate (`docs/remote/hosting.md:271-276`): the rest of the user's shell start-up can change the environment
after the first, and the selector also applies pins and pool ownership. Phase 0 times the shell start, and the two
selector calls inside it, separately. If the selector's `nc` check is a real share, the fix is to cache that one
reachability answer for a few seconds, which changes no selection.

A pre-warmed pane would hide the user's `.zshrc` entirely, and `hosting.md` chose a fresh login shell on purpose.
**Not proposed**; the owner decides with phase 0's number.

### 3.7 No terminal tab by default

Today every hosted start from the Mac opens a tab (`SessionStore.swift:1067-1071`). With a transcript and a
composer in the window, the tab is a second place to look and costs an `osascript` and an app switch. The sheet
remembers a choice, **Open in a terminal**, off by default once [PRD 3](03-transcript.md) and
[PRD 4](04-composer.md) phase 1 have shipped, on until then. Show in Terminal stays one key away (`⌘↩` in the
viewer, as today).

### 3.8 Switching stays instant

Covered by [PRD 3](03-transcript.md) section 2: a write appends to the cached window instead of dropping it.
Until that lands, the interim fix is one line of policy: a change to a cached conversation that is not open marks it
stale and keeps it, so a switch paints the stale page and refreshes it, instead of showing a spinner.

## Phase 0: measure

No step above is timed today. `Perf` wraps one-shot bridge calls and routes (`Sources/SideA/Perf.swift:18,25`),
and `scripts/perf-summary.py` knows only those two event names (`:23,61-64`), so both gain a `start` family. Add
signposts and slow-call lines for: sheet open to Start enabled; Start pressed to launcher returned; launcher
returned to first live row; first live row to first transcript row; `live` duration; `show` duration; reader queue
wait; and inside the pane, shell start to agent start, with each selector call timed. One run on the owner's Mac with ten sessions going
decides the order of phase 2 and the pre-warm question.

## Phases

1. **Feels instant**: optimistic row, sheet closes at once, starting pane with prompt, trust card and held reply,
   auto-open on arrival, failure with Try Again. Sheet lists from disk and assigned independently. Stale-keep on
   switch.
2. **Is faster**: retry while booting and the watcher and predicate fixes; tmux pre-start; projects cache key;
   then, only where phase 0 points: ports off the `live` path, the selector's reachability cache, `codex-env`.
3. **Background start** (`⌘↩`) and the terminal-tab default, after PRDs 3 and 4.

## Proof

- With the fake agents (`Tests/SideATests/Fixtures/FakeAgents`): Start returns control to the UI before the
  launcher finishes (the fake launcher blocks on a semaphore; the row exists and the sheet is gone while it is
  held).
- The Starting row becomes the live row without the selection changing (`eventually`, no sleeps).
- A fake agent that prints a trust question raises the card on the Mac.
- A start that fails restores the draft.
- A Codex session under a temporary `CODEX_HOME` in `codex-conversations` is noticed without the 20 s loop.
- Try Again reuses the launch's key: with a launcher that succeeded but whose answer was lost, no second session.
- Phase 0 numbers recorded before and after in this document.

## Risks

- **A Starting row for a session that never comes up.** The 120 s grace ends it with the error and Show in
  Terminal, as on the phone.
- **The 500 ms retry** runs only while a launch is booting, for at most the grace. It is not a new permanent poll.
- **New files on disk**: the last projects list and options under the runtime folder. `SECURITY.md` lists what
  Side A writes and is updated with them.
- **Stale-keep** can show a page that is a few messages behind for a moment. It is replaced as soon as the refresh
  lands and is never shown with a composer bound to the wrong state: the composer reads live state, not the page.
