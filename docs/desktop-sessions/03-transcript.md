# The Mac transcript (PRD 3)

Status: proposal. Facts taken at **cb60816**. Depends on [PRD 1](01-shared-session-kit.md). Index in
[README.md](README.md).

## Recommendation

Replace the Mac viewer's rendering with the shared layout and rows, fed by wire types, and update it by appending
what changed instead of re-reading the page. After this the Mac shows everything the phone shows in a conversation,
and a phone transcript improvement reaches the Mac by building it.

## 1. What the Mac does not show today

From `Sources/SideA/SessionViewer.swift` and the Mac's `show` in the bridge (tools flattened at
`bridge/sessions.py:1772-1777`, thinking filtered at `:1875-1876,1894-1895`):

| Missing on the Mac | On the phone | Wire |
| --- | --- | --- |
| Thinking | `ThinkingRow`, merged runs | `TranscriptMessage` role |
| Tool status, duration, output | `ToolRow` sentence, step pages with console, read, grep by file | `TranscriptTool` |
| Inline diffs in history | `DiffCard`: 3 hunks or 40 lines, then the full diff | `FileDiff`, `DiffHunk` |
| Images (pasted, read, screenshots) | tiles and a viewer | `ImageRef`, `GET /v1/images/{id}` |
| Subagent transcripts | card that opens a nested transcript | `?agent=` |
| Todo lists in history | neither app; the live plan shows on both (`Sources/SideA/SessionActions.swift:14-17`, phone `PlanCard`) | `TranscriptTodo` on the message |
| Turn folding ("Worked for 4m") | `TurnFold` | derived |
| Streaming | word fade on the live reply, settled blocks frozen | `transcript.append` |
| Messages cut at 6,000 characters | fetched whole on demand | `messages/{seq}` |
| Numbered lists, code language | full block Markdown | |
| Health card (stuck, loop, failing) with actions | card with Send a Message and Restart Fresh | `SessionFlag` |
| Handoff header and first-turn bubble | `HandoffViews` | `HandoffLink` |
| Session info | sheet | `RemoteSession` |
| Copy transcript as Markdown | menu | derived |

The Mac has things the phone lacks and they stay: find in conversation, the lineage row and fork markers, day
breaks, the details popover, hover copy.

## 2. Loading and updating

Today a file change invalidates the cache and re-runs `show --limit 150` for the open session, then SwiftUI diffs
150 rows (`SessionStore.swift:364-410`). The phone's path on the same Mac turns a file change into `append`,
`replace` and `reset` events from a cursor (`Sources/SideA/Remote/TranscriptStream.swift`), but it is built at
Remote start and speaks to sockets. [PRD 1](01-shared-session-kit.md) phase 2 splits its core into a service the
app owns with Remote on or off; this PRD is that service's first local subscriber.

- **A window, not a page.** The viewer holds a `TranscriptWindow` (moved to the kit) per conversation and applies
  events to it. An update is usually an append, but not always: a page can replace earlier messages, a compaction
  resets the generation, and the layout itself restructures (a fourth tool turns three flat rows into a group,
  `TranscriptLayout.swift:106-115`). So the rule is **stable identity and a kept scroll anchor**, not "append
  only": the reader's place is anchored to a message, and rows keep their ids across regrouping.
- **Paging by cursor.** Open loads the newest 50; "earlier" loads the previous page. The remote format clamps a
  page to 200 (`bridge/sessions.py:1961-1994`), so nothing loads a whole conversation in one call.
- **Find in conversation** today loads everything (`SessionStore.swift:916-921`) and searches in memory. On paged
  data it asks the index instead: the bridge's existing full-text search, scoped to this conversation, returns the
  matching message ids in order; stepping to a match loads the page around it (`--around`, which exists). Matches
  inside the loaded window are highlighted as now.
- **First paint.** The LRU of 24 conversations holds windows. Hover prefetch (120 ms rest) is kept. A cached
  session paints from the cache and catches up from its cursor, so switching back never shows a spinner.
- **Streaming.** The live reply is the last assistant message while the session is working. It renders through the
  shared streaming Markdown, with the word fade off under Reduce Motion and on macOS versions without
  `TextRenderer`.
- **Whole messages.** A message cut at 6,000 characters is fetched by sequence, generation and subagent.
- **Lineage** (parent, forks, the focused message of a search hit) comes from its own small reply, since the
  remote page does not carry it.

## 3. Rendering

`TranscriptLayout.items(...)` then `rows(_:)` give the row list (`TranscriptLayout.swift:95,180`). Each row kind
has one shared view:

- User bubble: unchanged look, plus tinted slash commands (`CommandHighlight`).
- Assistant prose: shared `MarkdownView`. Selection uses the Mac's text selection across a whole message.
- Code: shared `CodeBlockView`, with the language shown and a copy button. No syntax colouring in this PRD.
- Tools: a run of more than three steps folds into a `StepGroupRow`; each `ToolRow` is one sentence ("Ran `swift
  test`", "Edited SessionStore.swift") with a status glyph. Clicking a row opens its step in an **inspector** on the
  right of the transcript (the phone pushes a page; a Mac window has the width to show it beside). `Esc` closes it.
- Diffs: `DiffCard` inline, "Show full diff" opens the inspector.
- Turn end: model, duration, copy.
- Finished turns fold to "Worked for Xm" and open on click; the live turn is open.
- Images: tiles; click opens Quick Look (`QLPreviewPanel`), which the Mac has natively.
- Subagents: a card; opening it shows the nested transcript in the inspector with a path back.
- Plan: the live plan stays above the composer, drawn by the shared `PlanCard`. A todo list in a past turn
  renders in place as a new layout item, which the phone gains too.

The Mac keeps a display setting the phone does not need yet, taken from T3 Code: **tool detail** (All, Only
failures, None), under the viewer's `…` menu, remembered per Mac. "None" shows the prompt, the folded turn and the
reply.

## 4. Keyboard

These apply when the transcript has focus, not the composer (the editor keeps `⌘↑`, `⌘↓` and the rest of its
own keys; the precedence table is in [PRD 5](05-sidebar-and-navigation.md) section 3).

- `⌘F` find. `↩` steps to the next **older** match and `⇧↩` to the newer, as today: find starts at the newest
  match, at the bottom, the way a terminal's does, so the natural next is upward. `⌘G` and `⌘⇧G` do the same.
- `Space` or `→` on a focused tool row opens it in the inspector; `Esc` closes.
- `⌘⇧C` copies the last reply. Copy as Markdown is a menu item without a key.
- `⌥↑` / `⌥↓` jump to the previous and next user message.

## 5. Phases

Each needs the matching views from [PRD 1](01-shared-session-kit.md) phase 3, moved as the phase's first commits.

1. Wire types in, old look out: rows from `TranscriptLayout`, shared Markdown, tool rows, turn folding, thinking.
   Lineage reply. Find on the index.
2. The local subscription: windowed updates with a kept anchor; cursor paging; streaming reply.
3. Inspector: step pages, full diffs, subagents.
4. Images, cut messages, handoff views, health card, session info, copy as Markdown, tool detail setting.

## 6. Proof

- A fixture conversation with every row kind renders without a dropped row (snapshot of the row list, not pixels).
- Identity under change, which the phone's `TranscriptIdentityTests` checks only for user and assistant messages:
  a fourth tool arriving (flat rows become a group), a page arriving mid-turn, a generation reset, a replace of an
  earlier message. In each, existing rows keep their ids and the anchored message does not move.
- Time from selecting a cached session to first paint is under one frame of bridge time: no bridge call on the
  path. Measured with a signpost, asserted in a test with a fake bridge that fails if called.

## 7. Risks

- **A long transcript in a `LazyVStack`** scrolls badly on macOS 14 when rows change height. Folded turns keep the
  row count low; if it is still poor the list moves to `List` with stable ids **(measure)**.
- **Find in conversation** assumes the old flat message list. It is rebuilt on the row list, searching the text of
  folded rows and opening them on a hit, as it does for tools today.
