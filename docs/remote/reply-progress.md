# Reply progress

Where a message sent from the phone stands, from the tap until the agent has read it or it is back in the field.
`ReplyProgress` (`Packages/SideAProtocol/Sources/SideARemoteKit/ReplyProgress.swift`) is the table as a value;
`ReplyProgressTests` walks every (state, event) pair against the invariants below. The phone's
`TranscriptStore.Outgoing.State` is `ReplyProgress.Stage`, and `TranscriptStore.mark` moves a turn only along it.

## Stages and what the bubble says

| Stage | Evidence | Label | Overdue after | Overdue label | Ways out |
| --- | --- | --- | --- | --- | --- |
| `sending` | the phone's flight: signing, outbox, request | Sending… | 30 s | Waiting for the Mac… | Copy; unanswered at the outbox's expiry (60 s) the phone holds it, and sends it again, as it went and under the key it went with, only if the session hasn't moved on, else gives it back ("the Mac may already have it"); one the Mac's receipts already name settles from them instead. To a Mac with `replies.seen` every reply carries `seen`, where the session stood at Send, and the Mac refuses one that moved on with 409 `session_moved_on` ("The session moved on while this waited…", text back in the field), after its idempotency record has replayed an attempt that already landed; a posted held reply then goes to the Mac to judge |
| `sent` | the Mac answered `typed` (Enter pressed); for a followed reply (Claude, Codex) also receipt `typed` | Sent to Claude (unfollowed: Claude reads it after this step) | 20 s | Claude hasn't taken it · 1m | Copy; the pane's check gives it back as `unsent` |
| `held` | receipt `held`: Claude's `queue-operation` enqueue, or Codex's `turn/steer` answer | Claude reads it after "<step>" (idle: Claude reads it next) | 45 s | the same and " · 3m", in the attention colour | Interrupt and Send, Copy |
| `note` | the Mac answered `note`; `RemoteSession.mail` | Claude reads it after this step | 60 s | the same and " · 2m" | Edit, Delete (Take Back), Copy |
| `queued` | the Mac answered `queued`; `RemoteSession.queued` | Claude reads it after this turn | none: it waits for the turn by design | | Send Now (with `replies.promote` one reply with `promotes`: out of the queue and delivered in one step on the Mac, as the session stands then, or 409 `queue_changed` and nothing sent; any other refusal leaves it queued; said under the field), Edit, Delete, Copy |
| `takingBack` | the Take Back is in the outbox | Taking back… | 15 s | back where it was | |
| `read` | receipt `read`, the transcript's user turn, the mail emptying, `followUp`/`inbox` | Claude read it | | | Copy |
| `unsent` | refused, unreachable, receipt `unsent`, `droppedReplies` | text back in the field, "Not sent · Retry" with the reason | | | Retry |
| `withdrawn` | Take Back answered 204 | text back in the field (Edit) or gone (Delete) | | | |

## Transitions

| From | Event | To |
| --- | --- | --- |
| sending | `typed` / `left` / `waits` / `taken` | sent / note / queued / read |
| sending | `refused`, `dropped` | unsent |
| sending, sent | `held` | held (a receipt can beat the answer) |
| sending, sent, held, note, queued | `read` | read |
| sent, held, note, queued | `dropped` | unsent |
| note | `amended` (a second note joins it) | sending |
| note, queued | `takeBack` | takingBack (remembering which) |
| takingBack | `takenBack` / `tooLate` | withdrawn / read |
| takingBack | `keptBack`, `overdue` | where it was |
| unsent | `retry` | sending |
| any with a patience | `overdue` | same stage, overdue |

The Mac's answer becomes its event by `ReplyResult.Delivery.event`, live and in the demo alike: `typed` → `typed`,
`note` → `left`, `queued` → `waits`, `followUp` and `inbox` → `taken` (the waiting hook hands it to the agent as its
input before the Mac answers, so it is `read`), and a delivery this build doesn't know → `typed`.

Every other pair changes nothing, so a late or repeated event (a `typed` answer after a `held` receipt) can't undo
what is known.

## Invariants (each a test)

- No unsettled state is a dead end, and every reachable state can reach `read`, `unsent` or `withdrawn`.
- Nothing waits without a time or a way out: every unsettled stage has a patience or a user action, and every
  overdue one has a user action or an exit the Mac takes on its own.
- A message is never delivered and in the field at once; `read` and `withdrawn` take no event.
- Take Back (Edit, Delete) is offered exactly where `takeBack` leads to `takingBack`, and from there a failure
  returns it to where it was.
- Retry is offered, and works, only from `unsent`.
- Interrupt and Send is offered only for a `held` message that is overdue, in a session whose stop gives it back
  (Esc in a hosted pane, Codex's turn interrupt), never for unhosted Claude's stop mail.
- With answers lost at any point and the user retrying, the Mac types a message at most once. A reply that was in
  the outbox may have been typed with its answer lost, so it goes again only under the `Idempotency-Key` it went
  with (`ReplyFlight.key`, sent as `Outbox.Item.key` under a new item id) and with the same body: held past the
  outbox's 60 s, Retry after `notDelivered`, Retry after a relaunch lost its outcome. The Mac's on-disk record
  (`IdempotencyStore`, 24 h, 1,000 per phone) replays the first answer, waits for a first attempt still running, or
  says `outcome_unknown` when Side A quit mid-attempt. Only after `outcome_unknown` does a Retry go under
  `<key>:r<n>`, which `ReplyReceipts.answer` answers from the first attempt while that one is followed and has the
  same words. A Send typed in the field never reuses a key, even with the same words. Not pinned by a test.
- An unsent reply keeps its photos for its Retry. A Send whose words include it takes them along; any other message
  (Send Now, Interrupt and Send, a dropped reply's Retry) never does, and once its Retry is gone they go back to the
  tray. Interrupt and Send takes the tray as Send is pressed, not when the stop is answered. Not pinned by a test.
- Replies that failed apart and come back joined in one field are new words: their Retry goes under a new key, and
  when one of them may have reached the Mac the reason says so.

## Which reply a line is about

- On the Mac each transcript or rollout line settles at most one reply: the oldest open one with the same text,
  whitespace and pasted photos aside. A line with only the same start settles none: Claude Code writes queued messages
  whole (3,000 local transcripts, none cut), and its cross-session messages all start alike. Two "yes" in one turn need
  two lines. A Codex user item with another message's `clientId` settles nothing by its text.
- A `remove` with `delivered_to_agent` was never followed by a record of the same message (3,000 transcripts), and one
  with `absorbed_mid_turn` by its `queued_command` echo or nothing, so only that echo is folded into its `remove`.
- On the phone one user turn in the transcript settles one bubble, the oldest first; the joined pass for Interrupt and
  Send's one prompt uses only user turns no bubble has settled. A bubble settled that way
  that the Mac later reports `unsent` still gets its text back in the field. A bubble whose receipt is `read` also
  goes once a user turn holds its text as a run of whole lines: Interrupt and Send's one prompt carries several.
- A Stop that finds nothing in the prompt leaves Claude's "let go" lines, read while it looked, to decide.
- A pane's "may not have been sent" check names the reply it was armed for; only that receipt becomes `unsent`.
- A reply with no word for an hour is no longer followed and leaves `receipts`; the phone keeps its last stage,
  overdue. On the Mac a watch's receipt (open, settled, expired) moves along `ReplyReceipts.Following.next` and its
  part in a Stop along `ReplyReceipts.StopState.next`, both tested state by event in `ReplyStopStateTests`.
- Several receipts turning `unsent` together (a Stop) come back into the field as one text, oldest first.

## Stop and Interrupt and Send

A Stop stops, and nothing else: it never sends what it found waiting. The phone's replies the agent hadn't read
come back unsent, with "Stopped before Claude read it." (or Codex), their text in the field for Retry. Interrupt
and Send (`InterruptRequest.send: true`) is a request to deliver: what the stop took back goes with the new message,
ahead of it, in one prompt, so the new message never waits behind a turn of their own. The overdue `held` bubble's
Interrupt and Send has no new message: with `interrupt.resend` it sends `resend: true`, and the Mac sends what it
took back by itself as the next prompt, once the prompt is clear or Codex's stopped turn has ended (30 s at most,
else back to the field as a Stop gives it); an older Mac gets a plain Stop, and the phone sends what comes back. Until that message reaches the
Mac only Side A's memory holds them: if Side A restarts meanwhile (a new epoch with no receipt for them), the phone puts
their text back in the field, "Side A restarted on <Mac> before this was read. It may not have been delivered.", unless
the transcript already shows them; other unread replies are still with the agent and only can't be checked. A reply
given back after it went, by a Stop or a receipt, brings its photos back to the tray. A phone that doesn't send
`send` gets a plain Stop; with Interrupt and Send its new message then goes alone and the earlier ones come back to
the field.

## Per session kind

| Kind | Hop | Evidence on the Mac | What can still go wrong |
| --- | --- | --- | --- |
| Hosted Claude | typed into the pane, Enter | `Hosting.owned` sees its own text before Enter (the whole prompt for a multi-line one, whose first row can be too short to tell); the verifier re-presses Enter for 60 s | the composer showed something else: `unsent` at once |
| | held | transcript `enqueue` | none known; a long foreground tool call holds it (p90 3 min, max 9 min seen) |
| | read | `remove` with reason `absorbed_mid_turn` or `delivered_to_agent` (its `queued_command` echo is the same message), or `dequeue` + `user`; another reason claims nothing | a line Claude wrote in a new shape: no word, so the receipt leaves after an hour |
| | Stop while typed or held | Esc (a `send-keys` that fails is no Esc: the replies stay where they were); Claude puts the text back in its prompt, which Side A looks for for up to 8 s (32 looks, 250 ms apart); when the whole prompt is the phone's replies (the newest of them), or those with one `[Pasted text #…]` placeholder standing for the one long or multi-line reply among them, and no one typed at the Mac, Side A clears it, in up to six rounds of backspaces, each only while what's left is that prompt cut shorter (a round that took only blank rows counts); `unsent` "Stopped before Claude read it.", the text back in the phone's field | anything else in the prompt, or it won't empty: left there, `unsent` "The stop put it back in Claude's prompt on the Mac, unsent."; nothing back within those 8 s: the transcript decides, a "let go" line seen meanwhile included |
| | Interrupt and Send | as Stop, then the cleared replies and the new message go as one prompt, theirs first, one per line; every receipt follows that prompt | no message within 30 s, or it can't be typed: `unsent` as Stop |
| Hosted Codex | typed, Enter steers, Tab queues | `Hosting.owned`, the verifier; receipt `typed` | the composer showed something else: `unsent` at once |
| | held | no evidence: the rollout keeps no queue, and the pane's pending-steer line isn't read | a steer behind a long tool call stays `sent`, overdue after 20 s |
| | read | the rollout's `response_item` user `message` with the text | |
| | unsent | a turn ended (`task_complete`, `turn_aborted`) without it and none started within 30 s | after Esc, Codex may have put it back in its prompt: the reason says so |
| | Stop, Interrupt and Send | as hosted Claude, when Codex shows the steer back in its prompt (not checked live); a Tab-queued one is left for its turn | nothing back: the rollout decides, as above |
| | Tab (`queued`) | receipt left out until `read` or `unsent` | |
| Unhosted Claude, hooks | note → PreToolUse/PostToolUse hook; follow-up → Stop waiter | `mail` empties; Stop waiter's answer | a note is read only at a tool boundary: none while Claude only writes text |
| Unhosted Claude, own tab | typed into its terminal (idle only) | receipts as hosted | Ghostty tabs have no screen check |
| Codex, shared app server | `turn/start` idle, `turn/steer` mid-turn, or `thread/queue/add` | receipt `typed`, by `clientUserMessageId` | |
| | held | `turn/steer` answered `{turnId}`: the running turn holds it until its step ends | |
| | read | `item/completed` `userMessage` with its `clientId`; out of Codex's queue, the text if the id is gone | |
| | unsent | pending at an interrupt Side A didn't send, or unseen 30 s after idle; also `codex.unsent`'s flag | |
| | Stop while held | Side A's `turn/interrupt` drops pending steers: `unsent` "Stopped before Codex read it.", back in the phone's field | |
| | Interrupt and Send | the dropped steers wait for the new message and go ahead of it, joined, as one `turn/start`; the message waits up to 20 s for the stopped turn to end (the phone 25 s before sending it) | no message within 30 s, or that `turn/start` fails: `unsent` as Stop; the turn not ended after 20 s: the message goes alone and the steers come back `unsent` at once |
| | queued | `thread/queue/add`, followed from before the call so a notification that beats its answer counts; `thread/queue/changed` + `thread/queue/list` show it leave the queue; receipt left out until settled | removed from the queue in the TUI: `unsent` 30 s after idle |
| Codex, unhosted | notes through its mail hooks | `mail` empties | needs the hooks trusted |
