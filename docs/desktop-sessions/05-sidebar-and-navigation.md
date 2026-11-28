# The sessions sidebar and getting around (PRD 5)

Status: proposal. Facts taken at **cb60816**. Uses the shared phases and grouping from
[PRD 1](01-shared-session-kit.md). Index in [README.md](README.md).

## Recommendation

Make the Sessions window something that can be driven without the pointer, and make "what needs me" the first thing
it answers. The sidebar's sections come from the same `SessionPhase` the phone uses; on top of that the Mac gets
the keyboard layer that the phone has no use for and that every good desktop agent app has.

## 1. Today

- A fixed 320 pt sidebar in a hand-rolled `HStack` (`Sources/SideA/SessionsView.swift:55-82`). It cannot be resized
  or hidden.
- The window removes its commands (`.commandsRemoved()`, `SideAApp.swift:52-57`). `⌘N` and `⌘F` are invisible
  buttons. `↑` and `↓` step through the list when the list or the search field has focus
  (`SessionsView.swift:140-141,415-417`); nothing moves between sessions from the composer or the transcript, and
  nothing is bound to stop, quit, pin, rename or archive.
- The app's **Player** menu is live in this window: `⌘↩` Use Selected Account, `⌘←` and `⌘→` Previous and Next
  Account, `⌘L` Accounts (`SideAApp.swift:43-49`). A menu key equivalent is handled before the focused text view
  sees the key, so in the composer `⌘←` changes the selected account instead of moving the caret. That is a bug
  today **(confirm by running)**, and it decides the design below.
- Waiting and Ready rows have no real context menu; history rows cannot be resumed from their menu.
- History groups by raw folder while the running list folds worktrees into their repository
  (`SessionStore.swift:203-212` against `:938-951`).
- No snooze, no pull-request state on rows, no undo, no multi-select. All four exist on the phone or on the wire.

## 2. Sections

The Mac keeps the order it has and gains Snoozed. It is deliberately not the phone's order (Pinned, Needs You,
Working, Ready, Idle, Snoozed, `apps/ios/.../SessionsView.swift:208-227`): the Mac's Pinned section is pinned
*history*, and a pinned running session shows where it runs.

1. **Needs you**: what the Mac calls waiting today, plus a launch showing a trust prompt or an error.
2. **Ready**: finished and not yet looked at. This is the island's ready list, as now; opening the session or
   answering from the island clears it.
3. **Working**, with starting sessions at the top ([PRD 2](02-fast-start.md)).
4. **Idle** (folded, with Quit Idle).
5. **Snoozed** (folded). A snoozed session that comes to need you leaves it, as the wire already arranges.
6. **Pinned** history.
7. **History**, by project, worktrees folded into their repository as the running list does.

Which section a running session is in comes from the shared `SessionPhase` (requests and waiting; working and
starting; finished; idle, `Model/Stores.swift:6-24`), so the two apps agree on what a session's state *is* even
though they order the sections differently.

### Rows

The row is the phone's fact line on a Mac row: title, status glyph, a working clock while working, and one line
that shows the first of: the request, the failure, a flag, waiting mail, the snooze, the current step. On the right,
chosen by width: pull-request state and number, ports, memory. Hover actions stay.

Every row kind gets the full menu for its state. The menu is built from one shared **action descriptor** list in
the kit (which actions a session in this state offers, in what order, which are destructive), which is new; each
app maps a descriptor to its own command. The actions themselves exist on the Mac already: Reply, Stop, Pin,
Rename, Fork, Restart Fresh, Hand Off (`SessionCommands+Handoff.swift`, which has had no Mac UI), Continue, Show in
Terminal, Archive, Quit, Copy ID, Copy Resume Command, Open Pull Request.

### Snooze, and undo

Snooze is the phone's (1 hour, 3 hours, tomorrow morning, until it needs me). The service exists on the Mac, but
its lookup and its change notice go through Remote's event hub (`RemoteRoutes+Snooze.swift:18-31`,
`RemoteController.swift:70-71`); it gets a local observer so it works with Remote off.

Archive, snooze and unpin show a five-second Undo and are simply reversed. Quit is different. An idle session with
nothing running is quit after the five seconds unless undone, and its state is checked again at that moment: if it
has started working or grown a request, it is not quit. A session that is working, has an open request, a
background task or a listening port asks first, as today and as the phone does
(`Features/Tools/SessionActions.swift:101-117`), and has no Undo.

### Selection

`⇧`-click and `⌘`-click select several rows. The menu then offers what applies to all of them: Archive, Pin,
Snooze, Quit. Each row is acted on separately; if some fail, the toast says how many and the failed rows stay
selected.

## 3. Keyboard

The window gets a real **Session** menu, so every action is discoverable and VoiceOver can reach it. While the
Sessions window is key, the Player menu's items are disabled: they act on the player window, and disabling them is
what gives the composer its `⌘←`, `⌘→` and `⌘↩` back.

### Who gets a key

In this order; the first that wants the key takes it.

1. **A sheet or alert.** Its default and cancel actions, and the New Session sheet's own keys.
2. **A focused text editor** (composer, search, find, switcher). It keeps every standard editing key: `⌘Z`,
   `⌘⇧Z`, `⌘A`, `⌘←` `⌘→` `⌘↑` `⌘↓`, `⌥←` `⌥→` `⌥↑` `⌥↓`, `⌘⌫`, `⌥⌫`. No session command uses these while
   an editor has focus. The composer adds only `↩`, `⌘↩`, `⌥↩`, `⇧↩`, `Esc`, and `↑` and `⌥↑` when it is empty.
3. **The focused surface**: the list (arrows, `↩`, `⌘⌫`, `Space`) or the transcript.
4. **The Session menu**, anywhere in the window.

### Session menu

| Key | Does |
| --- | --- |
| `⌘N` | New session ([PRD 6](06-new-session.md)) |
| `⌘K` | Switcher (below) |
| `⌘1` … `⌘9` | Open the nth running session in the list, top to bottom, as shown. Number hints appear on rows after `⌘` is held 200 ms, so a quick shortcut never flashes them. (Settings uses `⌘1–9` for its tabs in its own window.) |
| `⌘⌥↓` / `⌘⌥↑` | Next and previous session (the phone's iPad binding) |
| `⌘⌥A` | Next session that needs you, wrapping; then the next Ready one |
| `⌃Tab` | Back to the session you were in before this one |
| `⌘[` / `⌘]` | Back and forward through opened sessions |
| `⌘J` | Focus the composer |
| `⌘⇧J` | Focus the list |
| `⌘0` | Show or hide the sidebar |
| `⌘F` | Find in the conversation, or focus search when none is open (as today) |
| `⌘.` | Stop the open session |
| `⌘T` | Show in Terminal, or Resume for a past session (today `⌘↩`, `SessionViewer.swift:125`, which the composer now needs) |
| `⌘⌥P` | Pin or unpin |
| `⌘⌥R` | Rename |
| `⌘⌥S` | Snooze menu |
| `⌘⇧A` | Archive a past session |

With the **list** focused: `↩` opens and moves focus to the composer, `⌘⌫` archives a past session or quits a
running one (with the rules above), `Space` previews without moving focus.

With a **request** showing and the composer empty, `⌘↩` allows it. Deny has no key: it is the button, or typed
text sent as the reason ([PRD 4](04-composer.md)).

`⌘Z` undoes the last list action while its toast is up and no editor has focus.

`⌘⇧S` keeps opening the Sessions window from anywhere (`SideAApp.swift:40`). `⌘L` stays Accounts. The island's
global keys are Control-Option (`HotKeys.swift:11`) and nothing here touches them.

### The switcher

`⌘K` opens a centred field over the window. Empty, it lists sessions that need you, then recent ones, so `⌘K ↩`
is "take me to the next thing". Typing filters by title, project, branch, account and model at once (the phone's
`matches`), then falls through to full-text history search on the existing index. A `>` prefix lists actions for the
open session instead. `↩` opens.

## 4. The window

- The sidebar resizes by dragging its edge, hides with `⌘0`, and remembers both. Built as a draggable divider on
  the existing layout, not `NavigationSplitView`: the same behaviour without rebuilding the window's toolbar and
  focus handling around a different container.
- The title bar carries the open session's title and state; the window title is what Mission Control and the Dock
  menu show.
- The toolbar holds New Session, the switcher field, and for a live session Stop and the changes chip.
- The error toast dismisses itself after a few seconds and on the next action (today it waits for a click,
  `SessionViewer.swift:35-46`).

## 5. From outside the window

- The menu-bar popover's "N waiting for you" opens the first one today. It keeps doing that, and the same `⌘⌥A`
  order decides which is first.
- A global shortcut to open the switcher from any app is **not** proposed: the island answers requests without a
  window, and `⌘⇧S` already opens this one.

## 6. Phases

1. Session menu and shortcuts over today's list, with the Player menu disabled in this window; `⌘1–9`,
   next/previous, next needing you, back; resizable sidebar; toast. No kit needed.
2. Sections on `SessionPhase`; shared row facts and the action descriptors; worktree folding in history.
3. Switcher.
4. Snooze with its local observer, undo, multi-select.

## 7. Proof

- Unit tests on the ordering function that backs `⌘1–9` and `⌘⌥A`, with fixtures in every phase.
- The action descriptors for a session in each state are pinned by a table test in the kit.
- A key test per precedence level: `⌘←` in the composer moves the caret and changes no account; `⌘⌫` in the
  composer deletes to line start and quits nothing.
- A delayed quit whose session started working during the five seconds does not quit it.
- VoiceOver: each row exposes its actions (kept from today) and the menu commands are reachable.
- Reduce Motion: the number hints and the switcher appear without animation.
