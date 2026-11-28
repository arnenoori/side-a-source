# One session kit for the phone and the Mac (PRD 1)

Status: proposal. Facts about the tree were taken at **cb60816** (`main`, 2026-11-25). Part of the set indexed in
[README.md](README.md). The transcript, composer and sidebar-section work depend on this one; the first tranche does not.

## Recommendation

Add one Swift target, **`SideASessionKit`**, to `Packages/SideAProtocol`, and move into it the session logic and the
session views that today live only in the phone app. The phone app and the Mac app both import it. The Mac's Sessions
window stops reading its own cut-down transcript format and its own model types, and reads the same wire types
(`TranscriptMessage`, `TranscriptTool`, `RemoteSession`) the phone reads, produced by the same bridge call
(`show --format remote`), in process, with no socket.

The positions this document takes:

1. **Share the model and the layout first, the views second, the stores never.** The layout logic
   (`TranscriptLayout`, `TurnFold`, `ToolLabel`, `SessionPhase`) is free of UIKit, but it is written against types
   nested in the phone's stores and against the app's default main-actor isolation. So each piece is **extracted**
   (its inputs made plain values, its API made public) before it moves. Views move one at a time behind an explicit
   host context. The phone's stores (`AppModel`, `MacTools`, `SyncEngine`) do not move: they exist to talk to a Mac
   over a network, and the Mac is the Mac.
2. **The Mac gets the wire types by calling its own code, never by connecting to itself.** `RemoteTranscript.page`
   (`Sources/SideACore/Remote/RemoteTranscript.swift:15`) and `WireBuilders.session` already build the wire types in
   process for the phone. The Sessions window calls them directly. No loopback HTTP, no pairing, no signing.
3. **A move never changes the phone.** Each file moves with its tests, the phone builds against the kit, and the
   phone's test suite is the proof. A move that needs a behaviour change on the phone is split: move first, change
   after.
4. **Two seams.** Selectable text (`UITextView` on the phone, `NSTextView` on the Mac), and a host context that
   carries what a shared view asks of its app. Everything else is plain data passed in.
5. **The Mac keeps its host records and gains projections.** `LiveSession` is not a duplicate of `RemoteSession`:
   it holds the pid and start time that Quit rechecks before it signals a process
   (`SessionCommands+Actions.swift:15-23`). `SessionInfo` holds search hits and fork points the wire's `PastSession`
   does not. They stay. What goes is the Mac's second *transcript* model, once the wire one carries everything the
   viewer needs.

## 1. What is wrong today

`Sources/SideA` never imports `SideARemoteKit`, and the Sessions window has its own transcript model:

| Mac type | Wire type |
| --- | --- |
| `SessionMessage`, `SessionDetail`, `MessageSegment` (`Sources/SideA/SessionModels.swift:40-91`) | `TranscriptMessage`, `TranscriptPage`; tools are `[String]` on the Mac, `[TranscriptTool]` on the wire |
| `ToolSteps` (`Sources/SideA/SessionViewer.swift:771-823`) | re-parses names out of summary strings that `TranscriptTool` already carries as fields |
| `ComposerSend`, `ComposerOutcome` (`SessionStore+Composer.swift:5-17`) | `ReplyMode`, `ReplySubmit`, and the kit's `ReplyProgress`, `ReplyBubble` |
| paging and caching in `SessionStore` | the kit's `TranscriptFeed`, `TranscriptWindow` |

The bridge has two output shapes for one conversation. The Mac's `show` flattens each tool to its summary string
(`viewer_row`, `bridge/sessions.py:1772-1777`) and filters thinking out (`:1875-1876,1894-1895`).
`show --format remote` keeps both, and already pages by `--before`, `--after`, `--around` and `--limit`
(`:1961-1994`, limit clamped to 200). So a phone feature that needs a field (tool status, a diff, an image, a
subagent id) cannot be ported to the Mac without first changing what the Mac reads. That is why the desktop fell
behind, and why the transcript work waits for this PRD.

Not everything waits for it. Focus, keyboard navigation, the Session menu, remembered New Session choices and the
optimistic start need none of it ([README](README.md) section 3).

## 2. The target

`Packages/SideAProtocol/Package.swift` defines `SideARemoteKit` only on an Apple host (`:7-24`). `SideASessionKit`
is defined inside the same conditional:

```
SideAProtocol        wire types (all platforms)
SideASessionKit      session logic and SwiftUI views shared by both apps (Apple)   <- new
SideARemoteKit       phone client: transport, sync, reply state machines (Apple); imports SideASessionKit
```

- Depends on `SideAProtocol` only. Nothing in `SideAProtocol` or `Sources/SideACore` imports it, so the Linux graph
  the daemon builds (`Daemon/Package.swift:26`) is unchanged.
- The Mac must not link the phone's transport to render a transcript. The pure reply types the shared views need
  (`ReplyBubble`, `ReplyProgress`, `MailLine`) depend only on Foundation, each other and wire types, and move down
  into `SideASessionKit`; `SideARemoteKit` imports it. So does a transport-free `TranscriptWindow` and its reducer,
  split out of `TranscriptFeed.swift:4-19` (the feed itself uses `RemoteClient` and stays).
- Platforms stay `.macOS(.v14), .iOS(.v17)`. Shared views guard newer **declarations** as well as modifiers: the
  word-fade renderer conforms to `TextRenderer` (`apps/ios/.../Markdown.swift:117-120`), which the minimums do not
  have, so it is `@available`-fenced with a plain fallback.
- The phone app compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` (`apps/ios/project.yml:104`) and most of
  what moves is `internal`. Every moved declaration gets explicit isolation, explicit `public`, and a public
  initializer where it is built outside the kit.

### The phone's other targets

`SideARemoteShared` is a framework with no package dependency, built `APPLICATION_EXTENSION_API_ONLY`
(`project.yml:110-127`). The notification content extension uses its Markdown parser
(`NotificationContent/NotificationCard.swift:319,333`) and the widgets use its formatting. So:

- What moves out of `SideARemoteShared` (the Markdown parser, `Formatting.duration`, `AgentLink.opens`) must be
  extension-safe in the kit, which it is (Foundation and SwiftUI only once the one UIKit colour is a parameter).
- `SideARemoteShared` gains the package product and re-exports it (`@_exported import SideASessionKit` is avoided;
  the two or three call sites in the extensions import the kit directly), and `NotificationContent` and
  `SideARemoteWidgets` gain the product in `project.yml`.
- The gate for any step that touches this is the full iOS build, extensions included, not only the app's tests.

### Lint

The exact-length entries in `.swiftlint-baseline.json` are on the Mac, not the phone: `SessionStore.swift` (type
body 992, file 998), `HostedSessions.swift` (type body 799), `SessionsView.swift` (file 923). Work in those files
goes into extension files; an edit inside them keeps the line count. `apps/ios` has no length entries, so shrinking
a phone file is safe; its other baselined lines must stay byte-identical or leave with the code they flag.

## 3. What moves, in order

Each step is one commit that builds and passes on both apps.

### Phase 1: extract, then move, the logic

For each row: first a commit in `apps/ios` that makes the piece take plain inputs; then the move.

| Piece | Today | Extraction it needs |
| --- | --- | --- |
| Transcript layout: `TranscriptItem`, `StepGroup`, `TurnEnd`, `items`, `rows` | `Model/TranscriptLayout.swift` | It names `TranscriptStore.AnsweredRequest` and `.Outgoing` (`:19,22,95-96`) and `RequestOutcome` (`Model/Stores.swift:168-184,245-258`). Those become top-level kit types. `Formatting.duration` (`:55`) and the app's `TranscriptTool.duration` extension (`:200`) move with it. |
| Turn folding: `TurnFold`, `folded` | `Features/Transcript/TurnFold.swift:5-82` | Follows the layout types. The row view (`:84-103`) reads `AppModel.mac` and stays until phase 3. |
| `ToolLabel` | `Features/Transcript/ToolRows.swift:5-62` | Moves with `TranscriptTool.duration` and `IslandAction.path`. Replaces the Mac's `ToolSteps`. |
| Markdown parser, `FileLink` | `Shared/Markdown/MarkdownParser.swift` | The UIKit colour (`:128`) becomes a style parameter, which joins the cache key (`:38`). `AgentLink.opens` (`Shared/Formatting/RequestText.swift:100`) moves too. |
| Streaming boundaries | `Features/Transcript/StreamingMarkdown.swift:69-92` | none |
| Command suggestions | `Features/Composer/CommandSuggestions.swift:5-20` | logic only; the list view stays |
| `CommandHighlight`, mention parsing | `Features/Composer/CommandHighlight.swift`, `FileMentions.swift` | public API. (The file *search* is a Mac actor, `Sources/SideA/Remote/FileMentions.swift`, and stays.) |
| Session phase, grouping, sorting, matching | `Model/Stores.swift:6-24,108-148` | Instance methods on `SessionsStore` reading `sortBy`, `groupBy` and extras become free functions with explicit inputs. `SortBy` and `GroupBy` move; `ListPrefsStore` stays. |
| Delivery choices | `Model/Steering.swift:13-71`; `Steer.available` at `Features/Composer/Composer.swift:10-38` | `Delivery`, `DeliveryChoices` and `Steer.available` move. What is offered (`Steering.swift:85-114`) reads abilities, hosting, hooks and waiting state from `AppModel`; it becomes one function of a `RemoteSession` and its open requests. |
| Launch presentation | `Model/SessionsStore+Launch.swift` | `launched` and `placeholder` become functions over rows and a `[name: Date]` map. Used by the phone only at first; the Mac's start is its own design ([PRD 2](02-fast-start.md) 3.1). |
| Grep grouping | view code in `Features/Transcript/StepPages.swift:155-184` | pulled out of the view so `GroupedMatchesTests` has a subject |
| Snooze presentation, pull-request summary, `ModelName`, `HistoryTree` | `SessionExtrasViews.swift:148-168` and others | `SessionSnooze.Choice` is already wire (`SessionExtras.swift:46-54`); only its titles and times move |

Tests move with their subject into `Packages/SideAProtocol/Tests/SideASessionKitTests` and then run on the Mac
without a simulator.

### Phase 2: the Mac reads wire transcripts

- A reader in an extension of `SessionStore` returns `TranscriptPage` through `RemoteTranscript.page` and
  `show --format remote`, as `TranscriptStream.page` does (`Sources/SideA/Remote/TranscriptStream.swift:98`).
- **What the old reply carries and the page does not** is supplied separately before anything is deleted: parent,
  forks and the focus message (`SessionModels.swift:60-69` against `bridge/sessions.py:2002-2004`). A small
  `lineage` bridge reply, read once per open, replaces them.
- **A local subscription.** `TranscriptStream` is built at Remote start (`RemoteController.swift:261-263`) and
  speaks to sockets through `EventHub` (`TranscriptStream.swift:23-27,43-47,71-87`). Its core (a file change for a
  session becomes append, replace or reset from a cursor) is split into a service the app owns whether Remote is on
  or not; Remote becomes one subscriber and the Sessions window another. Remote-off launch behaviour is pinned by
  `Tests/SideATests/Remote/RemoteOffLaunchTests.swift:77-107` and must hold.
- The viewer renders from `TranscriptLayout.items` then `rows`. `SessionMessage`, `MessageSegment`, `ToolSteps`
  and `viewer_row` are deleted when nothing reads them. `SessionDetail` shrinks to the session and its lineage.

### Phase 3: views

Moved one at a time, each taking the host context in section 4, in the order [PRD 3](03-transcript.md) needs them:
Markdown and tables, code block, tool row and step group, turn fold row, diff card, plan card, thinking row, turn
end row, image tiles, subagent card, approval and question cards, the queue list.

### What does not move

- `AppModel`, `MacTools`, `SyncEngine`, `TranscriptFeed`, `Outbox`, signing: phone transport.
- `SelectableText`, `ComposerField`, the attach drawer, camera, Photos, dictation recorder: iOS UIKit.
- Navigation chrome and typed routes (`Route`, zoom transitions): each app keeps its own shell.
- `LiveSession`, `SessionInfo`, `HostedSessions.Session`: the Mac's host records.

## 4. The seams

A shared view never navigates. It reports what was asked for, and the app decides whether that is a pushed page
(phone) or an inspector (Mac).

```swift
/// What a shared transcript view may ask of the app showing it. Passed through the environment.
@MainActor public struct TranscriptContext {
    /// Which conversation, and which subagent's thread of it: a whole-message read needs all three.
    public var generation: String
    public var agent: String?

    public var show: (TranscriptDestination) -> Void      // .tool(TranscriptTool), .diff(FileDiff), .code(String, language: String?),
                                                          // .file(path: String, line: Int?), .image(ImageRef), .subagent(String)
    public var copy: (String) -> Void
    public var whole: (_ seq: Int) async throws -> TranscriptMessage
    public var image: (ImageRef, _ thumbnail: Bool) async throws -> Data
    public var answer: (RemoteRequest, RemoteAnswer) async -> Void
    public var queue: (QueueAction) async -> Void          // .promote(id), .remove(id), .reword(id, String)
    public var style: TranscriptStyle                      // fills, spacing and motion each platform supplies
}
```

File links keep the parser's filtering: the parser decides what is a link, the context only opens it.

Selectable text is a view the app supplies through the environment, defaulting to SwiftUI `Text` with
`.textSelection(.enabled)`. The phone supplies its `UITextView` wrapper so its edit menu is unchanged.

## 5. Proof

- Phone: its whole test suite and the full build with extensions pass after each step, and
  `swift test --package-path Packages/SideAProtocol` runs the moved tests.
- Mac: a fixture conversation rendered through the layout produces the same visible text as the old viewer for
  every message the old viewer showed, plus the rows it dropped. One test pins this before `viewer_row` is deleted.
  Search-hit opening (`--around`), lineage and fork markers have their own before-and-after test.
- Linux: `scripts/linux-check.sh` passes.

## 6. Risks

- **Extraction is most of the work.** The moves are mechanical; making the layout independent of `TranscriptStore`
  is not, and it changes phone code that has tests. It is done on the phone first, under the phone's tests, with no
  Mac change in the same commit.
- **Two apps, one kit.** A kit change ships in both apps. The wire stays the compatibility boundary between an old
  phone and a new Mac; the kit is compiled into each and is not a wire.
- **macOS 14 fallbacks** make shared views plainer on old Macs than on the phone. Accepted.
