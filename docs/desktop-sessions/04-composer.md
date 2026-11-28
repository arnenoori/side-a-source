# The Mac composer (PRD 4)

Status: proposal. Facts taken at **cb60816**. Depends on [PRD 1](01-shared-session-kit.md). Index in
[README.md](README.md).

## Recommendation

Bring the Mac composer to what the phone's does, on the phone's logic, and add the keyboard habits a desktop
composer is expected to have. The text view stays the Mac's own `NSTextView`; what it shares with the phone is
everything around it: suggestions, mentions, delivery choices, the queue, the outgoing state.

## 1. Gaps

| Phone has | Mac today | Wire, already served by the Mac |
| --- | --- | --- |
| `@file` mentions with search | none | `GET /v1/sessions/{id}/files?q=`; in process it is a Swift actor, `Sources/SideA/Remote/FileMentions.swift:4-43` |
| Queue list: reword, send now, remove | none | `RemoteSession.queued`, `DELETE .../queue/{id}`, reply with `replaces` |
| Steer now / queue / restart turn, sticky per turn | Send Now, Send After This Turn, Send as Note in a menu | `RemoteReply.submit`, `InterruptRequest` |
| Outgoing bubble that follows receipts, with retry | a status line under the field | `RemoteSession.receipts`, `DroppedReply` |
| Reply to an ended session by typing (resumes it) | no composer on a past session | `StartHosted.resume` |
| Typed text answers an open question, or denies an approval with a reason | separate request panel | `RemoteAnswer` |
| Dictation | none | `TranscribeRoute` |
| Model chip in the composer row | chip in the header | `SettingsChange` |
| Fast mode | not shown, though `settingsFast` is changeable | `SettingsChange` |
| Hand off to the other agent on next send | phone only | `Handoff`, `RestartRequest` |

Most of what is missing is UI and a local adapter, not backend: `SessionCommands` already serves the Mac and the
phone (`SessionCommands.swift:5-7`), and reply, queue, interrupt, settings, resume and handoff all go through it.
What the phone's route adds on top, and the Mac's composer does not have, is listed in section 2 under Outgoing.

Drafts on the Mac live in memory and are lost on quit. Focus has a bug: `ComposerField.updateNSView`
(`Sources/SideA/ComposerField.swift:61-63`) takes first responder on every SwiftUI update, which can pull focus out
of the search field.

## 2. Behaviour

### A composer on every session

A past session shows the composer with the placeholder "Continue…". Sending resumes the conversation hosted
(`StartHosted.resume`) and shows the reply as outgoing until the session is up, the same optimistic path as a new
session ([PRD 2](02-fast-start.md)). This removes the trip to a terminal for the commonest reason to open history.

### Triggers

- `/` commands and `$` skills: unchanged, now on the shared `CommandSuggestions`.
- `@` opens file mentions, searched with a 90 ms debounce, inserting `@path` for Claude and the bare path for Codex
  (shared `FileMentions`).
- `↑` in an empty composer recalls the last prompt sent to this session; `↑` again goes further back. From the
  transcript, so it survives a restart.

### Sending while the agent works

What can be offered depends on the agent, on whether the session is hosted, on its hooks and abilities, and on
whether it is waiting, not only on "working" (`apps/ios/SideARemote/Model/Steering.swift:85-114`). That whole
policy moves to the kit as one function of the session, and the Mac asks it. Where it offers both, the default
while a turn runs is **Queue**, and the pick sticks for the turn (`DeliveryChoices`):

| Key | Does |
| --- | --- |
| `↩` | the default for this session's state |
| `⌘↩` | the other offered choice, when there is one; otherwise the same as `↩` |
| `⌥↩` | queue, when the session can queue (kept from today); otherwise it does nothing and the hint says so |
| `⇧↩` | newline |
| `Esc` | close suggestions, else interrupt when the draft is empty |
| `⌥↑` | in an **empty** field, put the last queued message back to reword. With text, it is the editor's own key |

`ComposerField` does not tell `⌘↩` from `↩` today (`ComposerField.swift:85-99`); it gains that. In the viewer
`⌘↩` currently means Resume or Show in Terminal (`SessionViewer.swift:125`); with the composer focused the
composer's meaning wins, and the viewer's moves to `⌘⇧T` ([PRD 5](05-sidebar-and-navigation.md) section 3).

Queued messages show as a compact list directly above the field: text, Send Now, Remove, and reword on click. This
is the phone's `QueueSheet` content laid out inline, since the Mac has the room. Reword and Send Now use the
existing atomic replace and promote paths (`SessionCommands+Admission.swift:62-80`), never remove-then-send.

### Outgoing

A sent message appears at the end of the transcript at once as an outgoing bubble and settles when the transcript
echoes it. A dropped reply shows Retry on the bubble. The status line under the field goes away.

The state machines (`ReplyBubble`, `ReplyProgress`) move to the kit, but they need inputs the Mac's sends do not
produce today. A Mac send carries no idempotency key, no `seen`, no promotion data
(`SessionStore+Composer.swift:128-144`); the phone's route supplies the key and records the correlation in
`SentReplies` (`RemoteRoutes+App.swift:211-223`); and admission marks are read through
`store.remote.events?.session(...)` (`SessionCommands+Admission.swift:94-95`), which is nil with Remote off. So this
phase first gives Mac sends a local operation id used as the idempotency key, moves receipt observation out from
behind Remote's event hub, and correlates the transcript echo by that id. Retry resends with the same id.

### Answering from the composer

The phone's rule, moved to the kit unchanged (`Features/Composer/SessionComposer.swift:27-31,105-218`): typed text
answers the selected request when it is a question request holding exactly one question, and denies an approval
that offers deny, with the text as the reason. With several requests open, or a plan, the text is an ordinary
reply. The request panel stays for the buttons; the local answer path already exists
(`Sources/SideA/SessionActions.swift:75-126`) and needs none of the phone's signing.

### Attachments

Images, as today, from paste, drop or the paperclip. A file that is not an image, dropped or chosen, is inserted
as an `@path` mention when it is inside the session's folder, and as its absolute path otherwise: both agents read
files by path, and the Mac is the machine the file is on. This needs no upload.

Storing arbitrary files is **not** proposed. Upload storage accepts image signatures only and re-encodes them
(`Sources/SideA/Remote/RemoteUploads.swift:43-62,91-101`); Codex takes attachments as image arguments
(`HostedSessions.swift:238`); the phone's importer is image-only too.

A reply is refused above 20,000 characters (`SessionCommands.swift:11,227`). A paste that would take the draft
past that is written to a text file under the app's runtime folder and inserted as its path, with a chip that says
so; `⌘⇧V` pastes inline regardless.

### The composer row

Left of Send: the model and effort chip (opens the existing settings popover, now including Fast when the session
can change it), and the mode. `⌘⇧M` opens model, `⌘⇧E` effort. Choosing the other agent stages a handoff for the
next send, with the phone's "Hands off to Codex when you send · Review / Keep" line.

### Drafts and focus

Drafts are saved per conversation under the app's runtime folder (private to the user, written atomically) and
restored on launch. A draft's image attachments are upload ids, and uploads are swept after their retention
(`RemoteUploads.swift:105-113`): a saved draft keeps its uploads alive while it exists, and a draft whose upload is
gone anyway restores with its text and a line saying an image has to be added again. A draft is deleted when it is
sent, cleared, or its conversation is archived, and all of them by Remove Side A. `SECURITY.md` gains the file.
The composer takes focus when a session is opened or when the window becomes key with no other field focused, and
never on a plain SwiftUI update.

## 3. Not in this PRD

- Dictation. The Mac already transcribes for the phone (`Sources/SideA/Remote/Transcription.swift`), so a Mac mic
  button is small, but macOS dictation (`Fn Fn`) already works in the field. Later, if asked for.
- Camera and the photo drawer: phone only.

## 4. Phases

0. The focus fix alone. It needs nothing else and ships in the first tranche.
1. Shared suggestions and mentions; persisted drafts; prompt recall.
2. Local operation ids and receipt observation; then the queue list, delivery keys and outgoing bubble.
3. Composer on past sessions (with PRD 2's optimistic start).
4. File paths from drop, large paste, composer row chips, staged handoff, typed answers.

## 5. Proof

- Unit tests for key routing (`↩`, `⌘↩`, `⌥↩`, `Esc`, `⌥↑`) against the shared `DeliveryChoices`, with a fake
  session in each state.
- A test that a SwiftUI update with the search field focused does not move focus.
- A draft written, the store torn down and rebuilt, the draft is back.
- Queue: with a fake hosted session, queue two, remove one, reword one; the calls are the atomic ones.
- With Remote off, a send still gets its receipt and its echo settles the bubble.
