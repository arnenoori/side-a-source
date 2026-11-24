# Changelog

## Unreleased

## 0.5.59 — 2026-11-24

Side A Remote asks for Face ID once while you use it, as 1.2 meant to, not at every message. Face ID now unlocks the key the way Apple documents for a Secure Enclave key, the app lock's Face ID counts as that first one, and a key that refuses a held Face ID asks once more and keeps the answer. The diagnostics log says why each Face ID prompt appeared.

Relay: a "Didn't send" notice is no longer forced silent. A health alert goes at the level the Mac asks, passive or active, and is never time-sensitive.

Side A Remote, redesigned:

Two tabs and a compose button. Sessions and Accounts sit at the bottom left, New Session is the round button at the bottom right, and Settings and Search open from the top right of Sessions. Settings is a sheet, with the app icons, the notification switches and a terminal font preview on its first page.

The Sessions list says more with less. A working session counts up by the second where the time was, one that needs you says Approval there and shows the command with Allow and Deny on the row, and the chip at the top left shows whether the Mac is a laptop or a desktop and reads "Reconnecting…" while the connection is down, in place of a banner. Swipe right to snooze or allow and left to quit; a quit from a swipe can be undone for five seconds. A Mac that said it went to sleep shows that in place of its list.

A finished turn folds to one line, "Worked for 1m 12s", with its answer under it; tap the line for the steps. The turn in progress reads "Working for 12s" and shows its latest step.

The message field always shows the model. Its second row holds +, the model with its effort, and one button that is the microphone when the field is empty, Send when it has text, a red Stop while the agent works, and Queue when you type while it works. Hold it mid-turn for Queue, Steer Now or Restart Turn. Tap a queued message to edit it in the field, or send it now from its row.

An approval sits right above the message field with Allow Once and Deny, and a reply typed while it waits denies it and tells the agent what to do instead. The model sheet has the permission mode under the models.

Accounts shows the account in use as a card for each of Claude and Codex, with the week's figure large and the other limits as bars, the other accounts as rows with a bar, a percentage and when they reset, and limited accounts folded into one row.

New Session asks "What should we build in side-a?" with your recent folders and the agent as chips above the prompt, and starts on the folder you used last.

An account's page counts what is used, like the list, where it counted what was left. The bar that says a session needs you now shows on Accounts and inside another session, and no longer on the Sessions list, where the row already says it.

New Session is a real button beside the tab bar now: tap it for the sheet, hold it for the folders you used last. It no longer passes through an empty tab on the way.

An approval can be allowed for the rest of the session. Where Claude offers to remember a rule for the project, the phone also offers the same rule kept only until the session ends, as Allow for Session on the card; the sheet lists both.

The magnifier on Sessions searches the list in place, and Search History carries the same words on to past sessions. While the agent works and the field is empty, the microphone sits beside Stop. The reply sheet shows the model too. A sent message always says Sent until the agent has read it. Swipe an account to the right, or hold it, to switch to it. Settings has a Dictation choice between your Mac and the phone itself.

Notifications from the Mac:

"Quiet while I'm watching" now does what it says. The Mac holds a push back only from a phone that is in front with that session open, and sends a request that is still waiting once the phone leaves it; a phone on the list or on another session gets the push. With the setting off, nothing is held.

A notification that fails to go is tried again, up to three times, when the relay or Apple can't take it right then, and a request you answered in the meantime is not sent. Taking a notification away can no longer arrive before the notification it takes away. After Side A restarts, notifications for requests that can no longer be answered are replaced with "Request closed".

A request nobody answered (Codex or a subagent handing it back to the terminal, the turn ending, or the session ending) no longer turns into "Answered" on your phone; the notification says what happened. A Ready notification that ran out its time stays as it was. The limit notification says the percentage, such as "Work is at 92%".

`remote.log` now says why a push did or didn't go: one line per phone with the kind, sent, suppressed or skipped, the reason and the relay's answer, so "why didn't I get a push at 14:02?" has an answer.

When your Mac comes back, the "Your Mac has gone quiet" notice is removed and nothing is shown in its place. Two Macs no longer replace each other's notice.

A plan too long to fit in a notification offers Open, not Approve. A request you answer from a notification that the Mac refuses stays on the Lock Screen with Allow and Deny, and a second notice gives the Mac's reason. Not Now on the notifications card no longer ends it: Settings and Test Connection offer Turn On Notifications until you have answered iOS's prompt. Requests can arrive as Time Sensitive, so a Focus no longer holds them. Side A Remote no longer asks for permission to show a badge.

Settings has a Theme choice: System, Light or Dark, for Side A Remote alone.

Change a Claude session's model, effort and mode from the phone when it runs in your own tmux, not only in Side A's terminals. Side A walks Claude Code's own /model picker, /effort slider and Shift+Tab in that pane, for this session only, while the session is idle and in front in its terminal; a reply typed meanwhile waits its turn. A Claude session in a Ghostty tab outside tmux says why it can't: its screen can't be read.

## 0.5.58 — 2026-11-23

App icon:

Choose the app's icon. Side A Remote's Settings > Appearance > App Icon and Side A's Settings > General > App Icon offer Midnight, Cobalt, Gold, Glass, Chrome and CRT Pixel besides the default. On the Mac the choice changes the Dock icon, the app switcher, About and alerts while Side A runs (macOS keeps the Finder icon fixed so the signature stays valid), and it is kept across launches.

Messages:

Side A Remote delivers what you type exactly once, to the turn you meant. Every reply carries where the session stood when you pressed Send, and one that arrives after the session moved on, because the phone was offline or it came from an older notification, comes back into the field ("The session moved on while this waited") instead of landing in a turn you didn't see. A Retry after a lost answer is never typed twice, and a message given back brings its photos with it and never sends them with a different message.

Side A Remote says where a message is, from the agent's own record. A reply to a Claude session in one of Side A's terminals says each stage: "Sent to Claude", "Claude reads it after “Running tests”" while Claude Code holds it behind the step it is on, then "Claude read it". Held for more than 45 seconds it turns amber, says how long and offers Interrupt and Send. One that never went in comes back into the field with the reason. Codex sessions say the same stages: a steer through Codex's shared server is held until Codex reads it; in a Side A terminal Codex gives no sign that it is holding a steer, so there it reads as typed until Codex takes it. Before you type, the field says what Send will do mid-turn, and each way to send says what it means: "Read after this turn", "Stops the current step, then sends".

Stop only stops. A message Claude or Codex hadn't read yet comes back into the message field ("Not sent · Stopped before Claude read it."), a pasted multi-line one included, instead of going as the next prompt. Interrupt and Send sends what the stop took back together with your new message as one prompt.

Queued messages are yours to change. The phone lists the ones waiting for a session's turn to end, to reword or remove, and each can go sooner: swipe one to the right, or hold it, to send it into the running turn (Steer Now or Send at Next Step, as the session takes them) or to Interrupt and Send. Send Now takes it out of the queue and sends it in one step on the Mac, so a turn ending at that moment can't lose it.

You can send while the Mac is out of reach. Send becomes Send When Connected, the message shows "Sends when connected", and it goes once the Mac is back, in the order typed, kept through a quit for up to 12 hours. A message whose session ended or moved on meanwhile comes back into the field with the reason. A Stop that couldn't be sent lapses after 2 minutes, so a stale one never lands on a later turn.

Approvals go faster: allow with a full swipe, or straight to Face ID, and swipe from one approval to the next. Compact, Review and Fork show a working pill while they run, Quit and Stop Server ask first only when the session is at work, and idle sessions quit without asking.

A working session says so under its title: "Working · 1m 12s · Running tests", counted by the second, in the place of the context line, which is back when the turn ends.

A Claude Code session's todo list shows as the plan card in Side A Remote and in the Sessions window, the way a Codex plan does: the current step and "n of m" above the message field, and every step on a tap. It follows TodoWrite and Claude Code's newer task tools (TaskCreate, TaskUpdate, TaskList, TaskGet), whichever the session used last.

Side A Remote asks for Face ID once while you use it. A session in a permissive mode (Bypass permissions, Auto, Don't ask, Codex full access) needs Face ID for a reply, and that Face ID holds until the app has been away for five minutes, the same absence that locks it. If iOS stops taking the held Face ID, the reply asks again once instead of failing.

Notifications:

Side A Remote's notifications keep a session moving without opening the app, and never lose what you type into one. A question has an Answer field on its notification, beside the choices the expanded notification already shows. Reply on a Finished notification for a session that needs Face ID (Bypass permissions, Auto and the like) opens the app on that session with your words in the message field and the keyboard up, so one Face ID and Send sends them. A reply the Mac refused for another reason comes back into the field, and a notification says why.

A reply sent from a notification while the Mac is out of reach waits on the phone, as one typed in the app does, and goes once Side A Remote reaches the Mac again. The notification says it hasn't gone yet. If it can't go in the end, because the session moved on or 12 hours passed, it comes back into the field and a notification says so. A typed answer to a question that can't reach the Mac goes into the field instead of waiting, since it would no longer be accepted after two minutes.

Side A Remote tells you when your Mac has gone quiet. If the Mac stops answering for ten minutes, which a crash, a power cut or a lost network all look like, the phone gets one notification, "Your Mac has gone quiet", tapping it opens that Mac, and "Your Mac is back" replaces it when it returns. Quitting Side A, turning Remote or Anywhere off, and sleeping are not outages: a Mac that says so first is left alone, and one that went to sleep is mentioned only after a day ("Your Mac has been asleep for a day"). Mac goes quiet in a Mac's Notifications settings turns it off. It needs this version of Side A on the Mac and the phone, and the relay updated.

A Finished notification goes away when its turn is over: when the session starts working again, is answered, or is cleared on the Mac. Ready shrinks quietly to the sessions still waiting, and the app clears what's left of it, and every "Answered", when it next connects.

Screen:

See your Mac's screen from Side A Remote, and work it. A display button at the top right of a session, or Mac's Screen in the + menu, opens a live view of the Mac: the whole display or one window, starting on the session's own terminal window when it has one. Pinch to zoom, drag to pan, double-tap to zoom to a spot. With Control on, a tap clicks, a long press right-clicks, two fingers scroll, and a key bar types, with Esc, Tab, the arrows and ⌘ ⌥ ⌃ ⇧. It is off until you turn it on at the Mac, in Settings › iPhone › Screen: one switch to show the screen, which asks for Screen Recording, and one to allow clicks and typing, which asks for Accessibility. Every open asks for Face ID, one device watches at a time, the Mac shows who is watching with an End button, and the stream stops the moment the app leaves the front. On Wi-Fi or Tailscale it runs at up to 30 frames a second; through the relay at 15, smaller, and the view says "Reduced quality over relay".

Dictation:

Side A Remote has its own dictation. The mic in the message field, and under New Session's prompt, records as soon as you tap it, with a live waveform and the time; × throws it away and ✓ stops it. The words land at the cursor, spaced from what you already typed, with the keyboard back to edit them; nothing is sent until you send it. Your Mac does the transcribing, with OpenAI's speech-to-text and a key you enter in Settings > iPhone > Dictation (`gpt-4o-transcribe` by default, the model editable), told to listen for the session's project, its file names, Claude, Codex and the usual programming words. The key stays on the Mac. When the Mac is out of reach or has no key, the iPhone transcribes on its own and says "Transcribed on this iPhone". A recording runs up to five minutes and shows the last half minute counting down; a call or Siri stops it and keeps what you said, and one that fails to transcribe stays for Retry, even when it comes back while iOS is asking for the microphone. Neither the Mac nor the phone keeps the audio or the words, and remote.log records only how long, how big and how it went.

New Session and composer:

The + beside the message field opens a short menu (Camera, Photos, Files, then File from This Session, Mac's Screen and Model & Commands), and holding it brings up your newest photos above the field: slide along them without lifting and let go on one to attach it, or let go first and tap one. The recent-photo strip softens at its ends and lifts the photo under your finger. Type `@`, or pick File from This Session, and the session's files are offered as you type; the one you choose takes the `@` word's place. The transcript and the list's Reply and Message share one composer, with a visible way to pick how a message is delivered.

While you write, a chip beside the + shows the session's model and effort and opens the Model sheet, where the chosen model sits on a highlight that slides to a new pick and effort is a track you drag along its stops. A session left on its default model reads "Default" on the chip, to VoiceOver as well, with no effort guessed from a model it may not be using. New Session's model chip ("Opus 5.5 · High") opens the same half-height sheet of the Mac's models, where the chosen one's effort opens as a slider with each stop named and the recommended one marked; a running session's ⋯ › Model opens it too.

Hand a session off from Claude to Codex, or back, from the Model sheet. Under the session's own models it lists the other agent's when your Mac has it installed and signed in, with an account picker if there are several. Picking one changes nothing yet: the chip shows "⇄" alone, the field asks for a "Message for Codex…", and Review shows what Codex will get: the goal, branch, changed files (a file named like a key or `.env` is counted, not named) and plan Side A writes down without a model, and your message, sent last exactly as you typed it. The recent turns that fit go with it too, picked when you send, so Review doesn't list them. Send starts Codex in the same folder and ends Claude once Codex is up and past its start; if Codex quits as it starts, on an expired login or a model it doesn't know, Claude keeps running and the phone says why, and the page becomes the new session, with Claude's conversation above a "Claude Opus 5.5 → Codex GPT-5.5 · Handoff ›" line that opens the prompt that was sent. The list shows one row, "Handed off from Claude", and History nests it as it does a fork. Going back to Claude picks up Claude's own conversation with only what it missed, on the model you picked for it. A long conversation hands off its first prompt and its newest turns, where it used to stop at the newest 200 lines and could lose the goal. After Side A restarts, the "Handed off from" line and the handoff's prompt are there from the first look, going back included. The whole handoff is kept on the Mac for 30 days and then deleted, on a Mac that stays up too, and one that never started is deleted at once, and nothing is handed off while the Mac is out of reach. Handing back to Claude puts the handoff line where Claude takes over again, and no handoff prompt shows as a message of yours. "Earlier with Claude" tries again when tapped or once the Mac is back, if it couldn't load the first time. Your message shows whole above the new agent's first reply, a "## Message" heading of your own included. If the new agent ends before it starts, the page comes back with your message in the field and the handoff still picked. A handoff or a Restart Fresh the Mac refused goes again once you've fixed what it said, instead of getting the same refusal back. A session waiting on you in its terminal isn't handed off until you've answered it. Photos on the message go to the new agent's first prompt, to Codex or back to Claude, as a new session's do, and only photos this phone uploaded itself; a Mac too old to take them says so and keeps them in the field, and a handoff that fails gives the message back with its photos. While a handoff is picked, the chip shows only while the field is empty; once you type, the line under the field ("Hands off to Claude when you send · Review") is the indicator and the field has the whole width. Send offers no Next Step or After Turn, since it hands off either way. Reply from the Sessions list shows the same “Hands off to Codex when you send · Review” line under the field, with Review and a way to keep the agent, and follows the new session once sent. In the Model sheet, the session's own model takes back a handoff picked there, even for a session whose model can't be changed.

Touching and holding New Session lists the sessions that need you and the ones most recently at work, ready to open with a slide and release. New Session remembers what you last started with on each Mac: the agent, model, effort, account and whether it was a worktree. Switching the agent or the model keeps the choices that still apply. It opens with the folders, models and commands it last had and refreshes them behind, and once started it lands on a Starting page shaped like the transcript to come. While it waits for the Mac it says "Starts when connected", Stop Waiting keeps what you typed, and Start waits up to 75 seconds for the Mac to come back.

Side A Remote remembers how you left each Mac's list. Group By, Sort By (Newest First, Name or Project) and whether the idle sessions are folded are kept per Mac, and the Mac picked in the Macs menu and the session open beside an iPad's list come back at the next launch. The list has a search field for running sessions, by title, project, branch, account or model, and the time on a working row counts up by itself.

Files:

Side A Remote can open the files a session writes or names. A file chip, a Markdown link to a file in the session's folder, or a path in inline code like `docs/plan.md` or `src/app.swift:42` opens the file itself from the Mac: Markdown and text, images in the photo viewer, and PDFs, web pages, spreadsheets and documents in Quick Look. Share sends the file. The Mac sends only regular files up to 20 MB inside the session's folder, following symlinks, and never `.env` files, keys, credentials, anything in `.git` or a tool's sign-in folder, or a file hard-linked from elsewhere on the Mac. Nothing under Library, `.claude` or `.config` in your home folder goes from any session, and a session started in your home folder serves nothing hidden, so sign-ins and shell history stay on the Mac. An `@` mention lists only files the Mac would send.

Connection:

Side A Remote knows when it has lost the Mac, and gets it back sooner. "Connected" means the Mac was heard from in the last seconds: the app pings every 10 seconds, and on coming back to the front it checks the connection it had (in 1.5 seconds after more than 10 away) and replaces one iOS closed behind its back at once. A dropped connection is tried again in a quarter of a second, a drop that recovers within a second shows nothing, and with no network at all the app waits for one and says "This iPhone has no internet connection". When the Mac can't be reached by any way for a few seconds, the app says "Side A on your Mac isn't reachable right now. It may be asleep or closed." rather than listing each way that failed.

Keep awake holds the Mac up for Side A Remote too. With "Keep awake while agents work" on, the Mac also stays awake while a paired phone is connected and for 30 minutes after its last request, so a Mac you are using from elsewhere doesn't go to sleep between replies. The menu says "Keeping awake · Side A Remote in use". The lid and battery options apply as before.

Sessions list:

A session's pull request shows on its row in Side A Remote: "#412 · checks passing" on the second line, with a glyph in the status colours (green passing or merged, red failing, grey while checks run). Session Info shows it as a chip that opens the pull request in the browser, and a long press copies the link; the row's menu has both. The link is the one Claude Code recorded, shown only when it is a github.com pull request; its state and checks come from `gh` on the Mac, read at most once a minute and only when `gh` is installed and signed in. Without it the row shows the link alone.

Snooze a session to get it out of the way. Swipe a row, or hold it, and pick 1 Hour, 3 Hours, Tomorrow Morning or Until It Needs Me; it moves into a folded Snoozed group with when it wakes. It comes back to its place early, with its usual notification, the moment it asks something, fails or stalls, is sent a message, or, for Until It Needs Me, finishes. While it sleeps, a finished turn doesn't notify; once its time has passed it does, and a timed snooze wakes on time after Side A or the Mac restarts too. A session that is asking something, has failed or has stalled can't be snoozed, and the phone doesn't offer it. The Mac keeps the snooze, so every phone shows the same list.

Undo for what the list does. Pin and Unpin, Snooze and Wake, Archive and Unarchive, discarding a New Session draft and removing the only queued message each show a short notice with Undo for five seconds, above the tab bar or the message field. VoiceOver reads it out, and ⌘Z takes it on an iPad with a keyboard. Undo puts back exactly what was there: an archived conversation that was pinned comes back pinned, and a discarded draft comes back with its photos. Typing a new draft takes the discarded one's Undo away, so it never replaces what you are typing. An idle session's menu has Archive too.

When a session stops on something you can fix, the row says what in plain words and its menu offers the one thing that helps. A conversation too long for the model offers Compact. A folder macOS hasn't allowed (Desktop, Documents, Downloads, iCloud Drive, an external disk) says which and to approve it at the Mac. A Claude or Codex login that expired, or was never there, names the account. Only the agent's own failures count, not a command of its that failed, and one the agent got past clears with its next reply. Session Info adds the agent's own words, with anything that looks like a key or token taken out on the Mac before it leaves, Basic, Token and Digest sign-ins, temporary AWS keys, Stripe keys and PGP private keys included.

Mac fixes:
- Side A quit by itself about a day after launch on a Mac where Tailscale is installed but not running, and nothing opened it again, so Side A Remote couldn't reach the Mac until someone did. The wait between checks for Tailscale overflowed after 63 of them. The same fault sat in the retry that registers a phone with the push relay, after about two and a half hours of a relay that can't be reached. Both waits now stop growing at ten times the first.
- Side A is opened again when it ends without being quit: a crash, or a kill. Its helper notices within a second and reopens it, at most three times an hour, and serves the pool meanwhile as before. The helper runs whenever Remote or pool mode is on. A Side A that was running when the Mac shut down is left to Open at login.
- At its next launch after a crash, Side A reads macOS's crash report and writes when it stopped and where to autopilot.log and remote.log.
- A Claude Code or Codex session through the pool stopped with "API Error: 502 Side A couldn't reach Anthropic: The Internet connection appears to be offline" whenever the Mac's network dropped for a moment, on a Wi-Fi roam or just after waking. Side A now waits up to 90 seconds for the network before answering, and a 502 after that lets the agent's own retries run.
- A pool session that stopped on a cut-off response was never asked to continue: only sessions on their own login were looked at. Pool sessions are now asked too, and none is asked while the Mac has no network.
- Side A's log no longer reports a main-thread stall or a slow call hours long after the Mac wakes from sleep: time asleep isn't counted.

## 0.5.57 — 2026-11-18

With Side A Remote 1.1 (27). The Autopilot switch for continuing sessions, the Continued rows and replies typed straight into a terminal tab reach Side A Remote with its next build.

Side A now sends "Please continue" to a session that stopped on something it can get past, once it can: after Autopilot moves its login, after its limit resets, after the pool refused it with every account out and one has room again, and a minute after a response was cut off by sleep or a dropped connection. Only idle sessions are asked, at most three times and 15 minutes apart, and each ask is written to autopilot.log and shown in Side A Remote's Autopilot list. Sessions stopped while Side A was closed or before a relaunch are still asked. "Continue sessions once a limit lifts" in Autopilot's settings, on the Mac and in Side A Remote, turns it off.

Side A can now type into a session's own terminal tab when there is no other way to reach it: a Claude Code or Codex session idle in a Ghostty tab (Ghostty 1.4 or later) or in a pane of your own tmux. Continuing a stopped session uses it, and so do replies from the Sessions window and from Side A Remote, which no longer has to move such a session into Side A first. What is typed arrives as your own message. In tmux, nothing is sent over a dialog or a draft already in the message field. Ghostty's screen can't be read, so there Side A types only when the session is what the tab shows in front, and presses Enter a second time only while the session's transcript shows the message wasn't taken. Terminal, iTerm, Warp, kitty and WezTerm tabs are not typed into.

Side A Remote's camera tile now opens in place. Tapping it grows the live preview to fill the attachment panel, with a shutter, a flash button (auto, on, off, shown only when the camera has a flash), a button to switch cameras, pinch to zoom, and a close that shrinks it back into the tile. A photo goes straight into the tray and the panel returns with the tile still live, so you can take several in a row. If a call or another app takes the camera away, the tile shows a camera glyph instead of a frozen frame. The full-screen camera is gone. The panel also fills the keyboard's height at every size, with a taller photo strip and the actions laid out two to a row, and the last one taking its row whole.

Side A Remote tints commands in the message field as you type, and in the message once it is sent, the way T3 Code and the Codex app do: a `/command` at the start of a message when it is one of the agent's commands, and a `$skill` anywhere in a Codex message when it is one of its skills. Anything else with a slash or a dollar sign, like a path or an amount, stays plain.

Side A Remote's + now swaps the keyboard for the attachment panel instead of opening something over it. The panel takes the keyboard's exact place and height, so the message field stays where it was, and tapping the field or the + (now an ×) brings the keyboard back in the same spot. With the keyboard down, the panel rises like the keyboard and the field rides up with it. It opens on a row of your newest photos led by a live camera tile, with All Photos, Files, Paste and Model & Commands below. Tap the camera to take a photo, tap photos to pick them, and pull the panel up for the whole library as a grid. On an iPad with a keyboard attached it opens as a popover from the +. The New Session sheet works the same way.

Fixes:
- Claude Code's newer wording for a spent 5-hour window, "You've hit your 5-hour limit", wasn't recognized, so a session stopped on it didn't mark its account as full until the next usage reading.
- With many models in a month, the legend under Tokens per day ran past the edge of its card and several models shared a color. The chart now draws the five most used models and folds the rest into Other, each with its own color, and the legend wraps.
- Each bar of Tokens per day sat on the day before its own in time zones west of Greenwich.
- A long account name could wrap its row under This week in Usage; it is now cut short.
- When Side A couldn't save its usage cache, the dropped replies or queued follow-ups, the approvals log or a finished hosted session's last screen, add itself to the login items, register the keep-awake helper, remove a handed-off session or delete its install from the relay, nothing said so. Each now writes the reason to the log. A conversation view that couldn't be rebuilt is reported the same way.
- Side A Remote didn't record a message it failed to send to the Mac, a state refresh that failed after an event it couldn't read, or a push payload or saved state it couldn't write. The reasons now go to its log, so Share Logs shows them.

## 0.5.56 — 2026-11-16

With Side A Remote 1.1 (26).


Side A Remote's + opens a drawer that grows out of the button: Camera, Photos, Files, Paste when a picture is on the clipboard, and Model & Commands. Photos turns the drawer into a grid of your newest pictures with a camera tile first; tap to number them, then Add N Photos sends copies flying from the grid into the tray as the drawer closes back into the +. Drag the grid up for more rows or down to close it. All Photos opens the full system picker, and it, the camera and Files work without allowing library access. With limited access the grid shows what you shared and a ⋯ lets you share more.

Paste works for pictures. With only a picture on the clipboard, Paste in the message field (and ⌘V on a hardware keyboard) attaches it; text, or text with a picture, pastes as text.

New Session in Side A Remote takes photos too: a + beside the folder and model chips opens the same drawer, and the photos go to the Mac with your first prompt. If a photo hasn't uploaded, Start waits for it or asks you to retry or remove it. Cancel asks before discarding photos you've added.

Side A Remote runs on iPad. Full width, Sessions is a split view: the list on the left and the session you picked beside it, with whatever is waiting on you at the foot of the list. Transcripts and settings keep a comfortable reading width instead of stretching across the screen. In a narrow window, in Split View or Slide Over, it's the iPhone layout. With a keyboard, ⌘N starts a session, ⌘1 and ⌘2 switch tabs, ⌘F searches, ⌘, opens Settings, ⌥⌘↑ and ⌥⌘↓ move between sessions, Return sends and Escape closes the + drawer. Drag a photo in from another app to attach it, in a session or in New Session. Settings says Touch ID on an iPad that has it.

Fixes:
- Scrolling a page or so up a transcript could freeze Side A Remote: taps did nothing and the phone ran hot until you quit the app. It now keeps scrolling and responding.
- In a session, code and tables scrolled under the title showed through it and ran into the context line. The title and the context line now sit on one bar.
- A finished reply showed Copy and Share twice, once under the message and again beside the model and time. It shows them once.
- After several failed tries to give the push relay a phone's notification token, a later, unrelated relay failure waited minutes for its first retry instead of seconds. The wait now starts over once the relay has every phone's token.
- A paired phone could attach a photo another paired phone had uploaded to the Mac, if it knew the photo's id. A phone now finds only its own uploads.
- Sign Out marked an account signed out even when Claude or Codex didn't sign out, leaving its login in the Keychain. It now waits for the sign-out and says when it didn't happen. Removing an account says when its saved sign-in couldn't be cleared.
- A large photo you had just picked or pasted could be left out when you tapped Start or Send before it finished getting ready. Its tile now shows at once and Start and Send wait for it.
- A reply, an answer or a Stop that Side A Remote couldn't save to send later (the phone's storage was full, or a notification action was writing at that moment) showed "Sending…" and never went. It says "Not sent" with Retry.
- A reply or answer that a notification action was sending when its time ran out could stay on "Sending…" for good, if Side A Remote wasn't connected to the Mac at the time. It now says "Not sent" with Retry once the notification's attempt has lapsed.
- When the Mac restarted while Side A Remote was refreshing a list (sessions, requests, hosted sessions or accounts), the old Mac's answer could replace what the restarted Mac had just sent. The old answer is now left out.
- A reply or answer waiting behind one a notification action was sending stayed on "Sending…" after that action gave up, was cut off or finished, until Side A Remote reconnected or sent something else. It now looks again every few seconds and goes, or clears, as soon as the notification's hold on it ends.
- Switching to another Mac in New Session while a photo was still getting ready, or still loading from your library, dropped that photo. It now goes to the other Mac once it is ready, and Start waits for it.
- Switching to another Mac in New Session while a photo was uploading to the first one sent it to both Macs. It now goes to the second only.
- On macOS's own Python 3.9, a failed request to Claude's or Codex's servers could end the bridge with an unrelated error instead of its message. Found before release; it reports the failure as before.
- Messages the Mac sends to Side A Remote said "iPhone" on an iPad ("This iPhone isn't paired with Side A", "Unlock your iPhone to do this"). They say "this device" now.

## 0.5.55 — 2026-11-16

Settings search finds what you meant. It reads a word as you type it, forgives a letter or two out of place ("updtaes" finds Updates) and words run together ("menubar"), and puts the closest match first with what you typed in bold. ↑ and ↓ move through the results and Return opens one. When nothing has every word, the nearest matches show; when nothing matches at all, No Results reads at the top of the list instead of the middle of the window.

Guided tour is no longer in Settings › General, and Remove Side A moved out of it: right-click Quit in the menu.

Side A Remote gets out of "update" by itself. When your iPhone said to update Side A on the Mac and you did, it kept saying so until you left the app and came back; pulling to refresh did nothing. It now asks the Mac again every 15 seconds and when you pull to refresh. The banner offers Check Again, or Update in App Store when it's the iPhone app that is behind, in place of Test Connection.

Side A Remote says what is wrong instead of showing a blank page. A session that can't load shows "Can't Load Messages" with Try Again, after a spinner that only appears when the wait is long enough to notice. New Session is off while the Mac is out of reach, and when your folders won't load it says so with Try Again in place of "No Folders Yet". A session still starting for half a minute makes Open Terminal the main button. The Accounts tab shows why it's empty when the Mac is offline, needs pairing again or needs an update, rather than "No Accounts", and a pull to refresh that fails says so. A Mac whose Side A is older than the app expects gets one "Update Side A on" row in Sessions, and History says the same instead of blaming the Mac for not sharing.

What you type is kept. A reply you started and never sent is still in the field after iOS closes the app, and a second reply that fails joins the first in the field rather than replacing it.

A single-choice question selects your option and waits for Send Answer rather than sending on the tap. Stop gives a tap of feedback, and a Stop the Mac refuses gives another.

Fixes:
- A transcript that failed to reload after the Mac restarted its history, or after a repair that couldn't finish, stayed blank until you left the page. The messages already on screen stay while the new ones load, and it asks again until they arrive and when the connection comes back.
- A session you started from your iPhone that ended before it appeared in Sessions said "Starting…" for good. It now says "Process Exited" and puts what you wrote back in the field.
- One event from the Mac that the iPhone couldn't read made it reconnect again and again. It now skips that event, reads the Mac's state afresh, and waits between reconnects.
- A reply, an answer or a Stop waiting to go out showed "Sending…" under a banner saying you were revoked or needed to update, and stayed that way. Once its time runs out it says "Not sent", with Retry, whatever state the connection is in.
- The iPhone gives the Mac's push relay its notification token again until the relay has it, when the app opens, when the network changes and after a wait that grows, not only on the next launch.
- A subagent's page keeps trying to read while it is open instead of giving up after five failures.
- A launch before the first unlock after a restart left Side A Remote connecting until you quit it. It connects when you open the app.
- A queued message that couldn't be read no longer holds back the ones behind it.
- Unlock no longer does nothing when the phone's passcode was removed after Side A Remote's lock was turned on.
- Copy, Share, Fork, Stop, the pager in an approval and the remove button on a photo are easier to hit. They look the same and sit where they were.
- Tapping a notification for a request opens that request when the app wasn't already running. It used to open Sessions and stop there.
- An Allow or Deny that never reached the Mac offers Retry instead of a line that only said "Not sent".
- Update in App Store, shown when pairing with a newer Mac, opens Side A Remote's page.
- A refused security key in Remote settings offers Try Again before Make New Key…. Try Again asks macOS once more and keeps your iPhones paired, so a Deny clicked by mistake no longer means pairing every phone again.
- A notification registration the relay missed is retried, a few seconds later and then less often, and again as soon as the relay is reachable. Before, an iPhone could stay without notifications while everything looked fine.
- An update that was told to install but never relaunched Side A no longer blocks the rest of the launch. After a minute and a half it lets go, and Check for Updates… and the scheduled checks work again.
- A library file that couldn't be read at launch is read again every minute, so fixing it brings Autopilot, usage and Remote back without relaunching. Nothing is written over it until it reads.
- A pool that failed to start is tried again by itself, after a minute and then at longer gaps, for as long as pool mode is on. Pool mode also no longer sits on Starting if the port never opens.
- Opening a search result in a session and then clearing the selection no longer leaves the spinner on.

## 0.5.54 — 2026-11-16

Side A Remote asks for Face ID once, not at every message. Replies to a session in a permissive mode needed Face ID each time because the phone never kept the first one; now one Face ID, including the one that unlocks the app, covers the next five minutes, and each message you send starts that window again. Leaving the app ends it.

Starting a session from your iPhone feels immediate. What you asked shows straight away instead of a blank page until Claude wrote its transcript, and the page fills in on its own rather than staying empty until you went back and opened it again. The new session shows in Sessions at once, under Starting, and by default it also opens a terminal tab on your Mac, so it's in your tabs there too (New Session's Tab on Mac chip turns that off). Any session Side A runs has Show on Mac in its menu.

Replying to an idle session from the iPhone works. A session idle in a terminal Side A doesn't run used to say "Not sent" whatever you tried; sending now moves it into Side A and types your message there. A session that ended takes a reply too: it resumes the conversation with your message.

Subagents have their own cards in the iPhone transcript, with what each was asked, how long it has been working and the first line of its answer. Tap one to read its transcript, even while it's still running.

## 0.5.53 — 2026-11-11

Side A keeps itself current. It used to look for an update once a day, so a Mac could run an old version for a day after a release. It now looks every hour and when the Mac wakes. A check made while offline is tried again 10 minutes later and no longer shows as a failed update. With Update Automatically off, an update found in the background appears in the menu as "Update to" that version instead of opening a window.

A background check that never finishes no longer stops the others. Accounts, limits and usage could stay as they were hours earlier until you quit and reopened Side A. Side A now gives up on a round after 25 minutes awake, records where it stopped in the Autopilot log, and starts the next one. Waking the Mac starts a round right away, and usage for Today is counted again when the day changes.

Fixes:
- Side A Remote reconnects to the relay on the first try after a dropped connection. The relay used to turn the first attempt away when the connection had been open longer than two minutes.

## 0.5.52 — 2026-11-10

You can message a Codex session in a Side A terminal while it works. It used to refuse anything until its turn ended. From the Sessions window, ↩ steers the turn and ⌥↩ sends your message after it. From your iPhone, Send steers the turn, and a long press on Send offers Steer Now, Send After This Turn, and Interrupt and Send.

## 0.5.51 — 2026-11-10

A message you send from your iPhone to a Claude session that is waiting on background agents now reaches it within about a second. The session counted as working, so the message used to wait for its next tool call, which could be many minutes away. A subagent can no longer take a message meant for the main session either.

Side A Remote keeps listening on Tailscale when Tailscale wasn't up yet as Side A launched. It used to check once and then wait for the network to change, so your iPhone could only reach the Mac through the relay until you opened Settings › Remote. It now asks again until Tailscale answers, and the Remote log records what Tailscale said.

Fixes:
- A Mac with the Tailscale app installed but not running is shown as stopped instead of not installed.

## 0.5.50 — 2026-11-10

Side A does less work while sessions are streaming. Each line a session wrote used to start a new helper process and re-scan every session; while anything is streaming that now happens at most every 2 seconds, and the conversation you have open still updates right away. A Codex session's status line can lag by up to 2 seconds as a result. Checking which sessions are live is far quicker with Codex sessions open, opening and paging a conversation is faster, and Side A Remote no longer rebuilds every session for your iPhone each time one of them changes. The first time you open a conversation after this update it takes a moment longer while its saved view is rebuilt.

Quit and Quit Idle no longer end a session that just got work from your iPhone. They used a list up to 20 seconds old; they now check again first.

The Sessions window and the island answer questions the same way. They had drifted: the two could send a multiple-choice answer in a different order. The Sessions window no longer ticks recommended options for you on questions that take several answers. On a plan, ⌃⌥N now opens "What should change?" as the Keep Planning tooltip says; it used to turn the plan down outright.

Fixes:
- A large photo sent from your iPhone over a slow connection is no longer cut off after 10 seconds.
- Turning Side A Remote off now ends its Live Activities and stops offering previews, and an iPhone you pair again is no longer removed 10 minutes later.
- Codex usage and cleanup now include sessions that ran under an account Side A added.
- Saving Claude's settings no longer rewrites accented letters, emoji and other non-English text in the file as escape codes.
- One unreadable transcript no longer stops the others from being indexed.
- On a new install, notifications about waiting sessions are no longer silent when the first notification Side A sent was about an account.

## 0.5.49 — 2026-11-09

Side A uses much less CPU when many sessions run at once. With dozens of sessions open it looked up every listening port on the Mac and re-read each session's transcript every time any session wrote a line; it now looks up ports at most every 15 seconds, so a dev server a session starts can take that long to appear, and re-reads only the transcripts that changed. Pool mode also spends far less time on each request it forwards.

New lines in your conversations show up sooner in the Sessions window and on your iPhone. With a large history, each one waited behind housekeeping that took over ten seconds; that now runs every few minutes instead of after every change.

A Codex conversation that looked at an image file which has since been deleted opens on your iPhone again; it used to fail to load. If a request starts needing Face ID after your iPhone first showed it, the phone is now told to look again instead of getting a plain refusal. Trading two accounts no longer leaves one of them locked for a minute when the other is busy, and the Sessions window keeps working after a malformed request to its reader.

## 0.5.48 — 2026-11-08

Pool mode keeps working when Side A is closed. Sessions started through the pool used to fail with "connection refused" the moment Side A quit or crashed, until you restarted them. A small helper now serves the pool on the same port whenever Side A isn't running, using the accounts and limits Side A last knew, and hands it back as soon as Side A opens again. New `claude` and `codex` commands keep using the pool too. macOS lists it under Login Items as Side A; turning pool mode off removes it. If pool mode can't start, Settings now says why instead of showing Starting… until Side A restarts.

The menu is tidier: Today and 7 days now sit on the same line as Sessions, Settings and Quit, and the Autopilot switch is gone from it. Autopilot is on unless you turn it off in Settings > Autopilot; when it's off, the menu says so and opens that page.

New installs start with sensible defaults. Pool mode turns on once your first account is signed in, Side A tells you when a session needs you, and it warns when an account passes 80% of its week (80% is new in the list). Side A Remote now sends limit warnings unless you turn them off. Settings you already changed stay as they are.

Updates install on their own. Side A used to download an update and then wait for you to quit it, which for a menu-bar app could mean weeks. Now it installs and restarts while you're away from the Mac or it's locked, once nothing is waiting for you in the island, no pool request is running and no sign-in is under way. Your sessions keep running through the restart, and the menu shows "Updated to" for a day, linking to what's new. Settings > General > Updates has one switch, Update Automatically; if you had turned automatic installs off, it stays off.

A full context no longer sends a notification to your iPhone. It still shows on the session.

Your iPhone buzzes less, and mostly when something is waiting on you. While you're using the Mac, nothing goes to the phone; if you step away for a minute or lock the screen, whatever is still waiting goes then, and anything answered meanwhile never does. Requests wait 10 seconds first, so ones Autopilot or the Mac answers straight away don't reach the phone; ones that need Face ID go at once. Finished sessions share one Ready notification per Mac, such as "3 sessions ready" with their names, that updates in place and only makes a sound once every 5 minutes. A turn that took less than 30 seconds waits to be included in the next one. Autopilot moving your sessions arrives quietly; running out of accounts still alerts you. Nothing is sent to a phone that has Side A Remote open.

Fixes:
- An account whose name contains a word like "idle" or "429" no longer confuses Side A about its login. A revoked login on an account named dev429 showed as Ready in Test Pool, and one named bridle was renewed over and over instead of asking you to sign in.
- Removing an account now forgets everything Side A had saved about it.
- A Codex limit window with no length no longer shows up as a "0-hour" window.
- The island's "hit its limit" line names the model that hit it, rather than always saying Fable.

The Mac app is calmer and closer to the iPhone app:
- Settings and the island no longer explain themselves in captions and footers.
- The arrow keys move through the session list instantly.
- The island opens only when the pointer rests on the notch, and stays a moment after it leaves. Notices wait while the pointer is on them.
- Keyboard shortcuts moved from labels under each request into tooltips.
- Sessions use the same names as on the iPhone: Needs You, Working, Ready and Idle. Buttons are in Title Case.
- Text uses the system sizes. With Reduce Motion on, things fade briefly instead of jumping.

Side A Remote:
- A reply you had already dealt with no longer comes back as "Not sent" each time the app opens.
- Moving to another session from a notification no longer makes the Mac think you've left the app, which sent you notifications for the session on screen.
- While the app is open, notifications from that Mac no longer show banners or play sounds.
- Autopilot's notifications now appear; the phone used to reject them.
- If the app can't open its storage, changing a setting says so instead of looking like it worked.
- New messages fade in quickly, and earlier messages load without moving what you're reading.
- The microphone that didn't dictate is gone, so an empty message shows a dimmed send button.
- Animations are shorter.
- Question options highlight when you touch them and start on the recommended answer.
- Quiet While Watching is gone, because the Mac now stays quiet whenever the app is open.

Side A Remote: leaving Wi-Fi falls back to the relay instead of dropping the Mac. Test Connection tries again rather than reporting the Mac unreachable while it waits to reconnect, and tests the Mac it was opened for. Settings is a tab, and notifications and the Live Activity are set for each Mac. The tab bar keeps its shape when you scroll.

## 0.5.47 — 2026-11-03

Update to installs the newest Side A, not one downloaded before a newer release came out. Once an update had downloaded, Side A stopped checking until it quit, so Update to kept offering that version and Check for Updates stayed greyed out. Now a download waiting to install is checked against the feed when you press Update to, when Check for Updates runs, and once a day; if the feed has something newer, the old download is dropped and the newest is fetched instead.

Pairing an iPhone is calmer and says what's going on. Pair iPhone… is never just greyed out: the row says what it waits for, such as a security key Side A can't use, with Make New Key… beside it, or no network, with Use Wi-Fi. The QR code is bigger and sharp at every size, and now opens getsidea.com/pair, so the iPhone's Camera can scan it too and offers the App Store when Side A Remote isn't installed. After you click Pair, the iPhone pulses until it really has its pairing, then turns into a check; a pairing the Mac couldn't save no longer says Paired, and a phone that was reconnecting as you clicked no longer finds the sheet gone. Each way a pairing stops says what to do next, Escape cancels from every step, and VoiceOver reads out each step.

Open Terminal keeps the terminal on its account when the account's name has a letter such as ß, ﬁ, İ or an accent typed as a separate mark. The terminal named the account differently from the shell line and followed Autopilot instead.

Hosted sessions keep updating after Side A's helper fails once while turning terminal hosting or Remote back on. Until a relaunch, sessions that ended stayed listed and the phone's terminals weren't told they had exited.

A Mac with more than ten iPhones set up for notifications now notifies all of them. The relay takes ten devices per send, and Side A put every phone in one, so none got the notification.

## 0.5.46 — 2026-11-02

Pair iPhone works on a Mac that has a developer certificate in its Keychain, and Make New Key can no longer delete one. Side A's search for its security key could return another certificate, such as an Apple Distribution one, which left Remote stuck on "Side A can't use its security key"; Make New Key would then have deleted that certificate. Side A now only ever uses and removes its own key. Update before pressing Make New Key on 0.5.45 or earlier.

## 0.5.45 — 2026-11-01

Logins are harder to lose, and "sign in again" now means it. A Keychain that doesn't answer no longer reads as an empty slot, which could put an old backup over a live login or say a login ended without asking Anthropic. A renewed login survives a slow Keychain and Side A being stopped midway. Only Anthropic saying `invalid_grant` ends a login, and first Side A looks for a newer copy it holds and tries that once; a 403 or anything else is retried later. When an account is full and the only free one needs a sign-in, one notification says so, with a Sign In button. `autopilot.log` records each renewal's status, error code, slot, age and whether a session was running, never a token. Autopilot no longer stops over a session that is exiting, reads a slow process list twice, and logs why when it still can't tell which logins are in use. Time limits for Side A's helper stretch when the Mac is under heavy load.

Side A Remote no longer loses keys typed as a terminal opens. A phone that reconnected and sent straight away could have its keys acknowledged and then thrown away by tmux as it started; they now wait until tmux is ready. A second request signed in the same second no longer fails as a replay.

A reply Queued on the Mac that can't be sent now comes back to the phone that sent it, even if the Mac or the phone relaunched or the phone was away when it happened. A queue file from an older Side A is no longer deleted quietly: the Mac says what wasn't sent and keeps the file. Two lost replies for one session both come back.

The Mac now notifies you when a paired iPhone's notification address changes, with Remove Device right on the notification, since that's what a stolen token could change without Face ID.

A phone still paired under an id its Mac no longer answers to, such as an old Side A Dev pairing, now offers Pair Again instead of failing every signed action, and pairing again removes the old record. Pooled requests no longer fail with a 502 when the server has just closed the connection they were about to reuse.

Side A Remote no longer risks an abort on iOS 26 when an object it holds is released; it was seen in tests and not on a phone. Reviewing this release also tightened a few things. A retry can only install a login known to belong to that account, and a token is read again under the lock so it is never spent twice. Undelivered words go only to the phone that sent them, and leave the Mac after three days or when you remove Side A. The pool resends only model requests after a lost connection, since a resend can bill twice.

## 0.5.44 — 2026-11-01

Settings now follow your data instead of the copy of Side A you changed them in, so every copy on a Mac shows the same Dynamic Island, keep awake, sound, banner, player and terminal choices. Sync with your other Macs carries them too, and the newest change to each setting wins. A setting that arrives works as if you had flipped its toggle, so turning on the island installs its Claude Code hooks. Remote and lid-closed keep awake stay per Mac.

Side A Remote recovers on its own more often. A connection that died silently is noticed and reconnected, a phone finds a Mac whose port moved, the phone tries again from "removed", "new security key" and "needs update" whenever it comes to the front, and a Mac that briefly can't read its paired devices asks phones to wait rather than telling them they were removed. Offline screens offer Pair Again, and say when the Mac is asleep, which it now announces before sleeping. Retrying a reply keeps its attachments and how it was being sent. Notifications follow a new device token while the Mac is out of reach, denied notifications link to iOS Settings, and Test Connection can send a test notification. Side A Dev now shows up on the phone as its own Mac ("… Dev"), so pairing it no longer overwrites a pairing with Side A; an existing Side A Dev pairing has to be made again.

Side A Remote is harder to fool. A push under a real request's id can no longer put harmless words on it and get your Allow: buttons work only when the notification says exactly what the phone decrypted, and the long-press card shows only that. A pairing link can't silently replace a paired Mac, and warns when its key or name doesn't fit one you have; links in agent text and terminals can't start pairing, and the review demo link asks before disconnecting your Macs. The app lock now covers open sheets, a locked app signs nothing, the app switcher shows a cover instead of your transcript, and requests show hidden characters as escapes and can't be swipe-allowed when they have any. Pairing now needs a code from Side A's own QR, which has always carried the Mac's id.

The Mac no longer listens on Wi-Fi by default, since Tailscale and the relay reach it from anywhere. Turn it back on in Settings > Remote if you pair over Wi-Fi only.

Remote is harder to abuse with a stolen phone token: a token alone can no longer run anything or get past Face ID. Replies, starts, restarts, quitting, cleanup and Mac settings now need a signature from an unlocked phone. Face ID is needed for keystrokes, replies starting with `!`, and replies to sessions in a permissive mode or one Side A can't read. Update Side A Remote to build 12 to keep using it with this Mac. Prompts can no longer be read as command-line flags, and a first prompt starting with `-` is refused. No edit can be allowed from the Lock Screen now, and edit notifications offer Open. The destructive guard reads commands as a shell would and flags more of them, including writes to startup files, git hooks and agent settings, and hidden characters now show in requests. Answering by itself no longer approves plans, and it tells the agent you haven't seen the question. Wi-Fi access is now off by default, since Tailscale and the relay tunnel reach the Mac without it. Sharing a pool checks the peer before reading anything, and is refused on a Mac signed in to Tailscale with a tag.

Your phone can now explain and steer rotation. Accounts opens with how many sessions are waiting on a limit and who is back when, what's left across your accounts and when it runs out, and where each login goes next. Autopilot's moves say why ("Work → Personal · 5-hour 96%") and open to the sessions they moved, and the list stays current by itself. "Limited" now means Autopilot agrees, Fable running out shows separately as "Fable out", plans show their size, and accounts that will drop out of rotation say why ("Sign-in ends Tue"). You can set First, Normal or Last, Autopilot per account, Move at and Follow Fable from the phone, each after Face ID; Pool mode stays on the Mac. An optional notification tells you when Autopilot moves your sessions or runs out of accounts, and the relay can't read it.

Answers and replies on Side A Remote recover better. Tapping Allow again after a refusal keeps one line that follows the new attempt, and goes through even if the Mac remembers refusing the last one. A reply never goes unsigned when it needs a signature: cancel Face ID and nothing is sent, and Retry keeps the text and photos. A reply waiting for the Mac survives the app being closed, and a refusal that comes later still shows. The Live Activity now keeps updating and ends when it should instead of freezing, and turning it off in Settings takes it off the Lock Screen at once.

Replies and logins are more honest about where they stand. A reply to a working Codex session outside its shared server is refused instead of showing Queued and never going. A queued reply to Claude now survives a Side A restart, and if its session ends first your phone and the notch say it wasn't sent. Go on a finished session now really ends its wait, so the phone stops offering a follow-up it would refuse. A Face ID Allow right after "this needs more now" goes through instead of repeating the refusal. Turning Live Activities off ends the card on your Lock Screen, and a phone that never reports one stops getting new ones. A browser sign-in that finishes while another account is being checked no longer leaves the account not ready. An account that needs a sign-in stays out of Autopilot's moves even when a running session still reports its limits.

Turning off Share with my other Macs while Side A is still asking Tailscale can no longer leave this Mac listening with the setting off, and sharing recovers by itself once Tailscale is on. Pool mode can be retried when its first start couldn't write its file. Closing the pairing sheet now ends any pairing connections left open shortly after, so they can't block the next pairing.

Side A Remote closes the gaps a final security review found. A reply, restart or continue can no longer slip past its signature when a session appears mid-request. A command padded off the card with any kind of blank, or too long for it, now opens the app instead of showing Allow, and the phone checks this too, so an older Mac can't get around it. From a locked phone you can now allow only reads of prose, pictures and source, and searches; edits, config files and anything named like a secret need the phone unlocked. The destructive guard now reads brace and glob command names, pipes and heredocs into any shell, inline Python and awk, `find -exec`, `cd` before a write, `cp -t`, `curl -o` and more of git's ways to run code. A follow-up queued from a phone is dropped when that phone is removed, or if the session then needs more than the phone proved, and your phone hears it wasn't sent. Rotating a phone's notification key needs a signature, signed messages can't come back with altered bytes, and each phone can hold 500 MB of photos on the Mac. Remove Device is how to cut off a lost phone: a stolen token can still read transcripts, images and search, and turn off that phone's notifications, until then.

## 0.5.43 — 2026-10-30

Pool mode now carries Codex. When Codex accounts are included, `codex` in Terminal goes through Side A, which keeps each conversation on one account and moves on when an account says it is out. Your history, skills and hooks stay shared with your normal Codex; the login commands (`codex login` and the like) still use your own. Side A never writes a Codex login, and doesn't renew the Mac's own, which the desktop app also holds.

Settings shows what is left across each pool, its last answer or refusal, and whether another Mac's pool is reachable. Test Pool checks every login without spending quota.

Each account can be set to be used First, Normal or Last, for Autopilot and the pool alike. A Last account, such as one that bills extra usage, waits until the others are out.

Sessions at a limit with nowhere to go now get a notification saying when the account is back and what would free them, instead of a line in the log.

Ready for the Max and Ultra plan names, and for verified Ultra accounts with no 5-hour limit: they count as the biggest plan, and Side A stops trying to start a window that doesn't exist.

## 0.5.42 — 2026-10-30

Pool mode can serve your other Macs. Turn on Autopilot > Pool mode > Share with my other Macs on the Mac that holds your accounts, then run the command it shows on each other Mac. Their `claude` commands then use this Mac's accounts over Tailscale: sign in once, in one place, with one Mac's limits and history covering all of them. Only devices signed in to Tailscale as you are served, behind their own key, which New Key replaces. When the sharing Mac is asleep or away, the others use their own logins; `sidea pool leave` stops using it.

## 0.5.41 — 2026-10-30

Pool mode keeps prompt caches for an hour, as Claude Code does with your own login. Behind a proxy Claude Code took itself for an API-key user and cached for five minutes, so any pause longer than that wrote the whole conversation to cache again and spent limits faster.

Pool mode is tighter. Only `claude` commands get the pool's address and key: the Anthropic SDKs read the same variables, so a script of yours would have run on your subscriptions. A base URL or token you set yourself is left alone. The pool answers only Claude Code and forwards only to Anthropic's API, so a crafted request can't carry an account's token anywhere else. A login Anthropic refuses is renewed on the spot, and a login that is only busy for a moment no longer asks you to sign in. Pressing Esc in Claude Code cancels the request upstream at once, the pool can't start twice, and quitting Side A sends new commands back to your logins immediately.

Signing out of an account keeps it signed out; 0.5.40 could put its saved login back. Signing out, removing an account and uninstalling now delete Side A's backup of that login, and a spare copy of a login that nothing uses is cleaned up before its next refresh can end the real one. A login that ends now asks you to sign in once, from wherever Side A notices it, instead of failing quietly in the log.

Finished automated runs (`claude -p`, scripts and the Agent SDK) no longer pop up in the notch; they wait in the Done list. Turn on Settings > Notifications > Include automated runs to see them. A reply that is JSON no longer shows as a lone bracket.

## 0.5.40 — 2026-10-30

Accounts stop getting stuck after a `/login`. Typing `/login` in a session, or a session saving an old login back, replaces whatever login that session's Keychain item held, but Side A kept trusting its own record of which item belonged to which account. Accounts ended up pointing at each other's logins, two of them at one item, so Autopilot had nowhere to move ("no free account has room") and Sign in refused with "sign in again after Side A frees it", which never happened. Side A now checks who owns each item on every check and before every sign-in, points each account at the item holding its login, and gives an account whose login is gone an empty item to sign in to. It also keeps each account's newest login aside and puts it back when a `/login` wrote over it and no item holds it any more.

Pool mode, in Autopilot and off by default, sends Claude Code in Terminal through Side A instead of trading logins between Keychain items. Side A keeps each conversation on one account for an hour, since a prompt cache belongs to one account, and gives a new conversation the account Autopilot would pick. When an account is full, the request moves to the next account before Claude Code sees an error, and running sessions don't have to pause first. Every reply updates that account's limits. Logins stay in their Keychain items and are renewed there; Side A listens only on this Mac, behind a key. A terminal pinned with `sidea use` keeps its account, and once Side A quits, new commands use your logins again. Anthropic doesn't support routing a subscription through a proxy, so it stays opt-in.

Settings has a search field: press ⌘F, type, and pick a result to open the tab holding that setting.

## 0.5.39 — 2026-10-26

Autopilot can answer for you overnight. With Answer with recommended after 1 minute on (Mac Settings > Autopilot, or the phone's Autopilot section), a question whose every part has a (Recommended) option gets those options once it has waited a minute, and a plan is approved with edits still asked for. Permission requests are never answered this way. Any answer first cancels the timer, and each automatic answer is logged and marked.

Renaming a session in Side A or from the phone now renames the running Claude Code session itself, so its terminal tab, prompt label and /resume show the new name. Side A keeps its own name only when the session can't be reached.

A request settled anywhere, in the island, a notification, the phone or the terminal, now leaves every other place at once. Settings on the Mac and the phone end with the version you run.

New Claude and Codex logins on the Mac join the account library on their own; one you removed stays removed. Add Account no longer needs a name: the account is named after its email at sign-in. A removed account leaves the phone at once.

Side A Remote says when an iPhone has to pair again before it can approve, change settings, open the terminal, switch accounts or turn Autopilot on or off. A pairing from before Face ID keys, or one whose keys the Mac didn't keep, used to fail each of these with only the Mac's message, after a Face ID prompt that couldn't help. Sessions now shows a Pair Again banner, and those actions skip Face ID until the pairing is new. A Pair Again that failed or was cancelled also no longer breaks the pairing it was meant to replace: the phone used to throw away its keys as the attempt began, so the Mac refused every signature from the old pairing afterwards.

Show terminal, Answer in terminal and Go now reach sessions in your own tmux. Side A finds the session's pane on your tmux server, switches to it, and brings forward the tab attached to it; with no tab attached, it opens one that runs `tmux attach` with the server's own tmux. A tmux inside another tmux is followed through both. Before, these failed with "Couldn't find that terminal". An automated run (`claude -p` from launchd, cron, a script or the Agent SDK) has no terminal, so the island no longer offers Show terminal or Answer in terminal for it and says what started it instead, such as "No terminal: started by releases-weekly.sh". A session in an SSH login says so, with the address it came from. kitty (with remote control on) and WezTerm now open the session's own tab rather than only coming forward.

## 0.5.38 — 2026-10-25

Finished sessions can leave the notch on their own. Settings > General > Dynamic Island > Clear finished sessions takes them out of the Done list 30 seconds, a minute or five minutes after they finish; Never, the default, keeps them until you go to them or give them work, as before. A session you're replying to stays.

Side A now prefers Python 3.11 or later when one is installed, falling back to 3.9 only when nothing newer is there. On 3.9 the island couldn't read Codex's `config.toml` or an administrator's requirements, so it asked about Codex Apps calls Codex's reviewer would have taken. It also finds Homebrew's `python3.15` and `python3.16` under their versioned names.

## 0.5.37 — 2026-10-25

The island no longer asks about Codex commands Codex settles on its own. Codex asks Side A's hook before its own reviewer, so with Approve for me on, every command it would have approved showed up in the island instead. Side A now reads the thread's settings and steps aside when Codex's auto-reviewer has the call: Approve for me, a turn that asked for strict auto-review, an app set to auto-review in `config.toml`, or an administrator's requirement. It steps aside for sessions started with `--yolo` too. For Codex edits, the island has a This session button: later edits to the same files are then allowed without asking, as Codex's own "don't ask again for these files" does. Patches that delete a file always ask. Commands still ask each time, because the hook can't see which folder a command runs in or what sandbox it asks for. Claude requests that an SDK host or a background subagent settles first leave the island once the call is done, and a subagent's request goes back after two minutes, as Codex's do.

The conversation viewer now shows prompts you typed while Claude was working, with any images pasted into them; they used to be left out. Codex conversations also show the errors that ended a turn and where the conversation was compacted.

The session viewer opens conversations again on a Mac that only has macOS's own Python. Python 3.9 rejected the viewer's request for a conversation, and for a search with a filter, as an invalid request because the session id came after its options, so the viewer could not open or search them. The bridge now reads the options first on every Python version.

Side A Remote, in beta: the iPhone app pairs with Side A on your Mac and shows its sessions, requests and finished turns. From the phone you can answer requests, reply, start and fork hosted sessions, change a session's mode, model and effort, review a turn's changes, switch accounts and turn Autopilot on or off. Actions that raise permissions or change accounts need Face ID. The phone reaches the Mac directly on your network or tailnet, or through the relay when it's away. The Mac's Sessions window gained the same composer, settings chip, plan, Changes sheet and menus.

A request whose path leads through a link to a sensitive file needs the same click as the file itself; a patch's move is judged where it lands; credential searches and more deletes need a click; and opaque commands never offer Always.

A hosted session's terminal no longer opens tmux's right-click menu over empty space. tmux 3.8 added that menu, whose items kill or swap a pane with one click, and Side A's tmux setup only turned off the ones it knew.

## 0.5.36 — 2026-10-15

Show terminal, Answer in terminal and Go land on the session's own Warp tab again. Side A found a Warp tab by its folder in Warp's saved session database, but Warp updates a tab's folder only after a command finishes, so a session started with `cd project && claude` was filed under the folder the tab started in and Warp only came forward. Warp now gives every shell a link to its own pane, and Side A reads it from the session and opens it, reaching the exact tab and split without Accessibility permission. Older Warp builds keep the folder lookup.

## 0.5.35 — 2026-10-15

The Running list holds still. It used to re-sort every few seconds, working first and then by memory, so rows moved under the pointer and clicks landed on the wrong session. Sessions now keep a fixed order, newest started first, and while the pointer is over the list nothing moves between Needs you, Finished and Running either; a Show updates button puts waiting changes in place. Hovering a row no longer reflows it: its actions cover the end of the row. Running sessions sit under their project, with worktrees under the checkout they branch from, and idle sessions fold into one row with their total memory and Quit Idle…. A working session always shows the step it is on; a large context is noted beside an idle session instead of replacing that line. Memory shows on a row only from 1 GB, with the exact figure on hover, so titles get the room. The count and total memory moved into the Running label, and ↑ and ↓ step through the list from the list itself, not only from search.

## 0.5.34 — 2026-10-14

Claude's multi-question forms fit in the island again. With four long questions, the form ran past the bottom of the island and Send answers could not be reached. Questions now show one at a time under tabs named for each question; picking an answer moves to the next, Back and Next stay on screen, and Send answers sits on the last. When every answer is still Claude's recommendation, Send recommended sends them all from any question. A question with long options scrolls, and a single long question moves out of the title into the scrolling area. ⌃⌥1–4 picks an answer on whichever question is showing. Answers picked so far survive folding the island into the notch, Show terminal and stepping to another request. VoiceOver reads each question as the form turns to it.

## 0.5.33 — 2026-10-14

Requests answered in the terminal no longer linger in the island. Claude Code keeps Side A's hook running after you answer its prompt in the terminal, so a question, plan or permission request stayed on screen, kept ⌃⌥Y, ⌃⌥N and the other island shortcuts taken, and left "Waiting for your answer in Side A" in the terminal until the session quit. Side A now reads Claude Code's session registry: once a session stops waiting after its request arrived, the request is dropped and its hook released within about a second. A request also goes when its session finishes its turn or its process is gone. Show terminal folds the request into the notch while you answer there, and a failure to find the terminal now shows instead of hiding behind the card. Answer in terminal brings that terminal forward. A finished session you quit leaves the Done list, and "waiting for you" banners and notifications clear once the session moves on.

## 0.5.32 — 2026-10-14

Signing in to an account whose slot holds a stray copy of another account's login now works; Side A used to refuse until the slot was "freed", which never happened. It still refuses when that copy may be the other account's only good login. A notification says when an account's login was replaced and which account to sign in again. Live limits from a session are dated by its last reply, not its statusline's last redraw, and a reading whose weekly reset doesn't match the account's own week is not credited to it, so a reply from before a trade no longer shows another account's numbers. Thanks to brandeddaniel, whose fork these three fixes come from.

## 0.5.31 — 2026-10-14

Fixes accounts asking you to sign in again after Autopilot moved sessions. A session could save the login it was on back over the one Autopilot had just moved in, leaving that account with no login. For an hour after each move, Side A now watches for this and, if it happens, puts the overwritten login back and undoes the move, so nobody has to sign in. You get a notification and a line in autopilot.log. An account whose saved login now belongs to someone else says so ("Login replaced by dallas.test's") instead of a bare "Sign in again", and failed renewals are logged too. In the menu, each account's bars read 5h, then Fable, then the week on the far right; once an account's week is used up, only the week shows.

## 0.5.30 — 2026-10-13

Usage never shows more than 100%. Past a plan's limit, once paid credits run, Claude reports readings like 101%; Side A now keeps every reading, including saved ones and Codex's, between 0 and 100. A limit that has already reset shows 0% instead of its last reading, in the menu bar, the menu, the player and Settings. Resets due within the minute read "in 1m" instead of "in 0m", and the weekly alert no longer fires for a week that has already reset.

## 0.5.29 — 2026-10-13

Run agents overnight. Settings > General > Keep awake while agents work keeps your Mac awake while any Claude Code or Codex session is working, including one waiting on a background command or a subagent, and lets it sleep about 2 minutes after the last one stops or starts waiting on you. Also with the lid closed keeps working with the lid shut, on power by default, after a one-time approval in Login Items: a small helper that can only switch the Mac's lid-closed sleep on and off, and that gives sleep back the moment Side A quits, crashes or updates, and at every boot. With the lid closed and sleep given back, Side A puts the Mac to sleep instead of leaving it running in a bag. The menu shows when it's keeping the Mac awake. Add account moved to Settings > Accounts; Autopilot, Settings and Quit share one row in the menu. The website is now one page.

## 0.5.28 — 2026-10-13

Fixes Autopilot leaving running sessions on a full account when that account's usage read asks you to sign in again: a session's own limit reading now counts, so they move. Autopilot writes every decision and its reason to runtime/autopilot.log, and notifies you when a move to an account with room fails instead of failing silently.

## 0.5.27 — 2026-10-13

See what your sessions cost your Mac. Each running session in Sessions shows the memory it holds, including the dev servers, test runners and builds it started, and the ports they listen on; open one in the browser, stop a server, or quit a session. Tiles above the list total it up, and Quit Idle quits sessions idle for 30 minutes or more in one click (resume any with claude --resume). When macOS reports memory pressure and sessions hold 4 GB or more, the menu warns that memory is tight and Side A notifies you, before the Mac freezes. A new Setup tab shows your CLIs, MCP servers (with a connection check), hooks, skills and agents, read-only. Clean Up shows what conversations take on disk, archives old ones into Side A's folder (restorable, nothing deleted) and removes git worktrees your sessions left behind, keeping any a session works in, with a commit on no branch, or with ignored files like .env. The menu shows one status line at a time, Sessions comes second in Settings, and the How it works page recreates the app in the browser.

## 0.5.26 — 2026-10-13

Answer sessions from anywhere: in Sessions, a conversation waiting on you shows its permission request with Allow, Deny and Always, its question's options or its plan's Approve, and a finished one has a box for its next task, which starts its next turn right away. A new Finished section lists sessions waiting for their next task. The menu shows how many sessions wait for you or finished and opens Sessions on them. With Notify when a session needs you on, a permission request's notification has Allow and Deny; destructive requests, questions and plans open Sessions instead. Claude's recommended answer to a question (the option it labels "(Recommended)") is marked and picked to start with, so a multi-part question takes one click: Send recommended answers. The website's How it works page shows the Dynamic Island, Running sessions and cache-aware Autopilot in motion.

## 0.5.25 — 2026-10-12

Safer Fable-share trades: when both logins have running sessions, a trade that can't finish is now undone, so the two never end up on one login. Side A first checks that the Keychain accepts writes to both, so a refusing Keychain stops the trade before anything moves. "Worth at API prices" now uses LiteLLM's public price list, fetched daily, so new models and price changes show without an update. The design and validation docs describe the app as it is today.

## 0.5.24 — 2026-10-12

Dynamic Island: turn it on in Settings > General and Claude Code and Codex ask for permission at the notch. The request grows out of the camera with the command, the file and a diff of the edit, and which project and account it's from. Allow, deny, or always allow with the rule Claude Code suggests, from anywhere: ⌃⌥Y, ⌃⌥N and ⌃⌥A work while a request waits. The terminal prompt stays open too; answer there and the island lets go. Destructive commands, like `rm`, a force push, a database drop or an edit to Claude Code's or Codex's settings, are marked and need a click: no shortcut or Always approves them. Several requests queue with a counter, and Show terminal jumps to the session's tab. Codex requests go back to Codex's own prompt after two minutes unanswered (approve the hook once with /hooks in Codex).

Claude's questions and plans come to the island as well: pick an answer (⌃⌥1–4) or type your own, and review a plan with Approve, Accept edits, or Revise with a note for Claude.

When a session finishes its work, the island chimes and shows its last message, and a Ready list keeps every session waiting for its next task. Reply (⌃⌥R) gives it that task right from the island: the session wakes and starts on it, with nothing typed into your terminal. Go (⌃⌥G) opens the session's own terminal tab, now including Warp. A session paused on background work doesn't count as done. Account changes, limits being hit and sessions waiting for input show in the island too.

Sessions now has a Running section: each working session shows the step it's on ("Editing IslandView.swift", "Running pytest") and is flagged when it needs a look: no progress for ten minutes, the same step three times over, a run of failures, or a context past 150k tokens that every step re-reads. Send a working session a note it reads after its current step and keeps in mind, or stop it before its next one, without switching to its terminal (Claude Code, with the island's hooks on).

Built to be fully accessible: VoiceOver announces each request and what the shortcuts do, ⌃⌥I moves keyboard focus into the island, Reduce Motion swaps the springs for fades, and on a display without a notch the island is a pill under the menu bar.

Usage shows what your Claude tokens would have cost at API list prices, for the last 7 and 30 days and by model, and can notify you once a week when an account passes 50, 75 or 90% of its weekly limit. When status.claude.com reports an incident that reaches Claude Code or the API, the menu says so and Side A notifies you once, so errors in your sessions aren't mistaken for a problem with your accounts.

Autopilot is cache-aware: a trade an account doesn't need yet waits until that login's sessions have paused for five minutes, since a session moved to another account resends its whole context without the prompt cache. An account that's out of room still moves at once.

Autopilot now plans each running login by the models its own sessions use, instead of by the newest session on the Mac. When Fable sessions spend their account's Fable share and no free account has any left, Side A trades with a login whose sessions only run other models, as long as the spent login still has room for them (an idea from brandedDaniel's fork). Fixes the --demo preview rewriting your Claude Code statusline to point at its temporary folder.

## 0.5.23 — 2026-10-09

Fixes accounts going to Couldn't connect, and Autopilot stopping, on a busy Mac: a slow `python3 --version` check no longer makes Side A forget the Python it found, and if Python is ever missing Side A checks again each minute instead of waiting for Settings to open, and failed readings retry as soon as it's back. Side A also finds Python by its versioned name (python3.14 and so on), so a Homebrew upgrade that leaves `python3` unlinked doesn't take it offline.

## 0.5.22 — 2026-10-09

One copy at a time: opening Side A while another copy runs hands over to the one you opened, unless the running one is newer, so two Autopilots never trade logins at once and updates never collide. Side A offers to move itself to Applications when opened from Downloads or a disk image, where updates can't install. If an update fails, the menu says so and links the download, and Save diagnostics records why. Settings > General shows the session search index's size with Rebuild, and a Remove Side A button that undoes its shell line, statusline and hook, deletes its caches and moves it to the Trash (accounts stay unless you choose to forget them). The first index of your history runs at background priority, and the index compacts itself after big deletions. Local builds are now Side A Dev, with their own identity and no updater. In Sessions, a message's time and copy button float on their own card at its corner instead of landing on the text around it.

## 0.5.21 — 2026-10-09

Sessions: a new Settings tab searches every Claude Code and Codex conversation on this Mac, by what you asked, what came back and the commands that ran. One list shows what needs you first, then your pinned conversations, then each project's conversations, with branches under the one they came from and a small equalizer on the ones that are working. New conversations from the terminal appear within a second. The viewer opens at the latest message, marks who said what, and folds tool calls into one line ("Ran 3 commands, edited 2 files"). A running conversation's button takes you to the terminal tab it's in; others resume with `claude --resume` or `codex resume` in the terminal you use (Ghostty, iTerm, Warp or Terminal). ⌘F finds within a conversation. Pin, rename or archive conversations; names and archiving stay in Side A and never touch Claude's or Codex's files. Filters live behind the search field and show as removable tokens. The index is local (SQLite, built in the background, newest first) and leaves automated runs out unless you include them.

Fast: the list paints from its last copy the moment the tab opens, and Side A keeps the conversations it has shown, so reopening is instant. Conversations are kept ready to display in the index and read only what's new, so even one with thousands of messages opens in a few milliseconds. A search hit deep in a long conversation opens on the messages around it, with Jump to latest at the bottom. Searching a common word takes about a second instead of six. A conversation still running somewhere Side A can't reach (tmux, a closed window) offers Branch instead of a button that can't find it.

Notifications: turn on Notify when a session needs you in Settings > General to get a notification when Claude Code asks for permission or input, even with Side A closed. Clicking it opens that conversation.

Sound effects: soft player clicks when the account changes, a session resumes, or a session starts waiting on you. Turn them off or set the volume in Settings > General.

## 0.5.20 — 2026-10-09

Ideas from brandedDaniel's fork. A running session's own limit reply ("You've hit your weekly limit") now counts as proof the account is out, so Autopilot trades its login right away even while the usage endpoint answers 429. Autopilot moves only to an account with room on every limit, not one about to hit its weekly limit, unless nothing else has room. Reads run three at a time instead of all at once. Accounts other sessions use are read as often as the active one, and a limited account is checked hourly in case its limit resets early. Fixes a crash whenever Side A posted a notification. `source ~/.zshrc && claude` uses the chosen account, and the shell line works under `set -u` and with `cat` aliased. A stopped bridge releases Claude Code's refresh lock at once.

## 0.5.19 — 2026-10-08

Running sessions switch: when an account with running sessions nears its limit, Autopilot trades its login with an account no session is using, and the sessions continue as that account within about 30 seconds, nothing to restart. Logins are never copied; both refresh locks are held and a failed write is undone. The move point is a setting (default 95%, was a fixed 97%). Autopilot reacts between replies instead of once a minute, and stale statusline temp files are cleaned up.

## 0.5.18 — 2026-10-07

Live limits: Side A wraps the Claude Code statusline so every reply saves that account's 5-hour and weekly numbers (from the response itself), then runs your own statusline with the same input. The usage endpoint is only read every 15 minutes while sessions report, for Fable, paid usage and use elsewhere, which ends its rate limits. On by default; Settings > Autopilot turns it off and restores your statusline exactly.

## 0.5.17 — 2026-10-07

Always-current readings: Side A renews expired Claude logins the way Claude Code does (its endpoint, client id, refresh lock and Keychain format), so idle accounts stay readable around the clock at no cost. Warns three days before a sign-in ends. A rate limit keeps the last reading instead of showing Couldn't connect, and the account in use is read every three minutes. Fixes 0.5.16 holding the Mac login's refresh lock while waking it.

## 0.5.16 — 2026-10-07

A new sign-in or a refresh is read at once instead of after a back-off; readings older than 15 minutes say when they are from. Side A takes Claude Code's own refresh lock while it runs claude for an account, so it never refreshes a login at the same moment as an open session.

## 0.5.15 — 2026-10-07

Countdowns move while the menu is open, and a limit estimate from stale readings is dropped. A login whose owner can't be checked yet no longer reads as Couldn't connect. Switch notifications explain that running sessions keep their account. Sign in again is in each account's menu.

## 0.5.14 — 2026-10-07

Usage lists Claude and Codex models in separate sections, so Codex is not crowded out. Codex turns count the way ccusage counts them, so a session total that restarts after compaction is no longer missed.

## 0.5.13 — 2026-10-07

Usage rows list every limit with its reset (5-hour, weekly, Fable); Accounts shows Fable bars and each reset under its bar; Today compares with what you usually use by this hour.

## 0.5.12 — 2026-10-07

Paid usage warnings: Side A reads each Claude account's usage-credit spend, warns before the account in use starts billing credits with nowhere to move, notifies when spend grows, and shows spend in Usage.

## 0.5.11 — 2026-10-07

Run accounts side by side: sidea use <name> or Open Terminal on an account keeps one terminal on it while Autopilot moves the rest. Weekly forecasts follow your usual rhythm, with a week-ahead summary. The Terminal prompt leaves the menu; Use and turning on Autopilot set it up.

## 0.5.10 — 2026-10-07

Accounts no longer sit on Reading forever: revoked Codex logins ask for sign-in instead of backing off as a rate limit, idle Claude logins can be woken (automatically during work hours, or with Wake), and failed reads say why with a retry time. Clearer Terminal setup prompt.

## 0.5.9 — 2026-10-07

Sync across Macs through iCloud Drive: combined usage, per-Mac totals, shared working hours and accounts from other Macs to sign in to. Follow Fable: while Claude Code runs Fable, Autopilot ranks accounts by Fable headroom and skips plans that bill Fable as extra usage.

## 0.5.8 — 2026-10-07

Redesigned Autopilot tab: live ranking with the scoring rule, a 24-hour day strip and rule chips. Pace verdicts predict when a limit runs out. Codex sessions count in Usage; GPT model names read cleanly; placeholder rows filtered. More site Easter eggs.

## 0.5.7 — 2026-10-07

Accounts tab grouped by provider with an In use label and live limits; Usage tab with weekly pace per account, period comparisons, per-model daily chart and an hourly activity strip.

## 0.5.6 — 2026-10-07

Reads per-model weekly caps from the usage endpoint's scoped limits and shows them once used. The 3D player is opt-in. Easter eggs on the site and in notifications.

## 0.5.5 — 2026-10-07

The disc is visible with the lid open: the lid seam was a solid cylinder that covered it.

## 0.5.4 — 2026-10-06

Open source under MIT; each release's source is published to arnenoori/side-a-source. Optional manual update installs.

## 0.5.3 — 2026-10-06

Menu bar pivot: the 5-hour and weekly limits for every account, shown as a percentage in the menu bar. Autopilot picks the Claude account with the quota closest to expiring and warms idle 5-hour windows during your usual hours. Selection is read-only: Side A never writes or refreshes a login; an opt-in zsh function points new `claude` commands at the chosen account, and an optional hook rechecks on a rate limit. Codex accounts are tracked and warmed, not switched. Usage by day, project and model. Removed per-project Terminal sessions and the PTY supervisor.

## 0.4.1 — 2026-09-07

Simplified tool readiness, automatic verification on return from sign-in, and physical OPEN/PLAY guidance. Transient verification failures preserve account readiness; reconnecting keeps Auto flip preferences. Added a private local diagnostic summary and consent-aware completed-setup metrics.

## 0.4.0 — 2026-09-07

Added signed Sparkle updates, local release automation, tool checks, and optional anonymous app metrics.

## 0.3.0 — 2026-09-06

Added Codex subscription profiles, native CLI sessions, verified identity, and
same-thread account switching through the app-server protocol. Auto flip waits for
completed work and a structured usage limit. Accounts stay grouped by provider for
handoffs; the LCD and menu bar show the selected or playing agent. Existing Claude
profiles migrate without changing sign-in metadata or Auto flip consent.

Accounts now opens in a separate utility window beside the 3D player. Removed the
sheet backdrop and the overlapping disclosure arrow from account menus. Onboarding
adds only a compact Claude/Codex selector.

Added provider migration, protocol, privacy, and real PTY switching tests. Codex
remains experimental until two real subscription accounts pass live acceptance.

## 0.2.1 — 2026-09-06

Reduced onboarding to a compact form. Removed the slogan panel, branded footer,
repeated headings, and numbered explanations. Shortened sign-in, account, and
settings copy while retaining field labels and the Auto flip access note.

## 0.2.0 — 2026-09-06

The standalone app is now just the 3D device. Removed the entire surrounding layout
and window chrome; added a transparent window, housing drag, LCD account/session
status and project selection, and accessibility actions directly on the model.
OPEN reveals onboarding after the lid animation. The menu bar companion remains.

## 0.1.0 — 2026-09-06

Initial Claude Code preview: native 3D account player, menu bar companion, isolated
login onboarding, verified account selection, managed Terminal sessions, and
opt-in rate-limit handoffs. Includes Blender source, reproducible app packaging,
security documentation, and native/PTY tests. Live multi-account acceptance remains
pending account sign-in; Codex and Claude Desktop integrations are not included.
