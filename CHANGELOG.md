# Changelog

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
