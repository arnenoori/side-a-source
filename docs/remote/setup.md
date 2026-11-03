# Side A Remote: setup

How someone goes from "I have Side A" (or "I have an iPhone") to a phone showing their live
sessions, and how either side finds out what is wrong when that stops working. This file owns the
journey and its copy. The pieces it strings together are specified elsewhere: the server and
pairing in [mac-server](mac-server.md), the phone's screens in [ios-app](ios-app.md), the wire
types in [protocol](protocol.md), push and the site's download section in
[relay-and-release](relay-and-release.md). Where this file changes one of them, the change is
listed under [Changes to other specs](#changes-to-other-specs).

Status: built and shipping (Side A 0.5.44). Written as the plan in October 2026; where this differs from the code, the code wins. Copy follows [design](../design.md): one
fact per line, plain words, real states only, no exclamation marks, no promotion.

**Transport assumed here** (from the security review, superseding Tailscale Serve in the plan and
mac-server): Side A terminates TLS itself on **one port** for REST and WebSocket, with a
self-signed key it keeps in the Keychain. It binds its **tailnet address** (and, optionally, the
LAN with the same TLS). Tailscale is only the network. The phone pins the key's SPKI hash, taken
from the QR code at pairing. Pairing ends with a **6-digit short authentication string** (SAS)
shown on both devices, which the user confirms match. The pairing code is **8 characters**,
carried only in the QR code; pairing is QR-only. No MagicDNS, HTTPS certificates or
`tailscale serve` are needed.

## Principles

- **One journey, many doors.** Every entry point ends in the same three things: the Mac checklist
  green, a QR code on the Mac, a matching 6-digit code confirmed on the Mac. Nothing has a second,
  shorter path.
- **The Mac goes first.** The Mac can check almost everything, including whether an iPhone is on
  its tailnet; the phone can check almost nothing (iOS can't see Tailscale's state). So the Mac
  carries the checklist, and the phone's job is to reach the Mac's QR code and then explain
  failures in terms of what to fix on which device.
- **The QR code pairs; it doesn't install.** The Mac shows `https://getsidea.com/pair#…`, which
  `site/public/.well-known/apple-app-site-association` hands to the app when it's installed; without
  the app, a Camera scan opens `/pair` and its App Store link. Phones from Build 13 also take
  `sidea-remote://pair#…`, the form Side A showed before 0.5.47.
- **Check, don't ask.** Every checklist row is a live check that re-runs on its own (tab opened,
  every 30 s while open, on wake, when Side A becomes active, as `DependencyStatusView` already
  does). Nobody ticks a box.
- **One thing to fix at a time.** Only the first unmet required step shows a button. Steps after
  it say "After the step above" in secondary text instead of a second error.
- **Ask for permissions when they mean something.** Camera when the scanner opens; notifications
  after pairing, next to a real session list; local network only if the user turns on Wi-Fi
  pairing; never on the welcome screen.

## Entry points

| | Starts at | Path |
|---|---|---|
| A | Side A on the Mac, no phone app | Mac: Setup tab row or tour step → Settings > Remote checklist → Pair iPhone → Camera scans QR → site install page → App Store → scan again in the app → codes match → Pair on the Mac |
| B | Phone app, no Mac app | Phone welcome → "Don't have Side A on your Mac?" → send the link to the Mac (AirDrop, Messages, Mail, Copy) → continue as A on the Mac. Or **Try a Demo** while waiting |
| C | getsidea.com | Remote section on the home page → `/remote` setup guide → "Open Settings › Remote" (Side A installed) or "Get Side A" (not) → continue as A |
| D | One phone paired, adding another phone or another Mac | Second phone: Mac › Settings › Remote › Pair iPhone, phone app goes straight to the scanner. Second Mac: phone › Settings › Pair Another Mac, the Mac runs its checklist |
| E | Re-pairing (revoked, phone app reinstalled, Side A removed or reinstalled, Mac's key changed) | The phone shows why, with **Pair Again**, which opens the scanner directly |

### A. Side A on the Mac, getting the phone app

1. The Mac learns about Remote in three places, all real states rather than promotion:
   - **Settings > Setup** gets a "Side A Remote" section at the top (see [Setup tab](#setup-tab)).
   - **The guided tour** gets one more step, `.remote`, ringed around the gear button: "Your
     sessions on iPhone: Settings › Remote." It's shown only while nothing is paired, and only in
     the tour (new installs, or Settings > General > Guided tour > Show again). Existing users see
     it once on the first launch of the version that ships Remote: the tour runs with only that
     step (`tourSeenRemote` in `UserDefaults`, separate from `tourSeen`).
   - **The release notes** of that version, as for any feature.
2. Settings > Remote shows the [checklist](#the-mac-checklist). Required steps gate the Remote
   switch. Turning it on starts the listener on the tailnet address.
3. **Pair iPhone…** opens the pairing sheet. Its instruction line covers both cases:
   "Scan with the iPhone camera. If Side A Remote isn't installed yet, the camera opens the
   download page."
4. Camera scan without the app: iOS opens `https://getsidea.com/pair#…` in Safari. The page
   ([Website](#website)) shows the App Store badge and "Then scan the code on your Mac again."
5. With the app installed, the same scan opens the app on the pairing screen, skipping the
   welcome. The code renews itself while the sheet stays open (see [Code
   lifetime](#code-lifetime-while-installing)), so the minutes spent in the App Store don't
   matter.

### B. Phone app first, no Mac app

The welcome screen (wireframe below) has **Pair with Your Mac**, **Try a Demo** and a text button
"Don't have Side A on your Mac?". It opens **Get Side A for Mac**:

- Title: "Get Side A for Mac"
- Body: "Side A Remote shows what Side A sees on your Mac. Install Side A there first; it's free."
- Requirements line: "macOS 14 or later, with Claude Code or Codex CLI."
- **Send Link to My Mac**: `ShareLink(item: URL("https://getsidea.com/remote"), subject:
  "Side A for Mac", message: "Install Side A on your Mac, then open Settings › Remote.")`. The share
  sheet carries AirDrop (the obvious one for a Mac next to the phone), Messages, Mail and Notes.
- **Copy Link**, a plain text button, with a `.success` haptic and "Copied" for 2 s.
- **Try a Demo Meanwhile**.
- Footer: "When Side A is running, come back here and tap Pair with Your Mac."

No email is collected and nothing is sent by us: Mail comes from the share sheet, addressed by
the user. The link is the `/remote` guide, not the GitHub releases page, so the person arriving
on the Mac lands on the setup steps with the download button at the top.

**Demo mode** is the one in [relay-and-release](relay-and-release.md#app-review): scripted Mac,
local notifications, local Live Activity, a pill "Demo · nothing is connected" with **Exit Demo**.
For setup it adds one thing: the Sessions toolbar in the demo has **Pair Your Mac**, which exits
the demo onto the Tailscale step. Leaving the demo never asks for confirmation; there is nothing
to lose.

### C. From the website

The home page's Remote section (before `trust-strip`, as relay-and-release plans) gets a "Setup
guide" link to `/remote`. The guide is the same journey on one page ([Website](#website)). Its
first button depends on nothing the page can detect reliably, so it shows both:

- **Get Side A** (the existing download button, `data-download="remote"`).
- **Already have it? Open Settings › Remote**, linking `sidea://remote/setup`. If Side A is older
  than the Remote release or not installed, the browser does nothing or says it can't open the
  link; the line under the button says "Needs Side A 0.6 or later."

### D. A second phone or a second Mac

**Second phone, same Mac.** Settings > Remote › iPhones › **Pair iPhone…**, the same sheet. The
new phone runs the full phone flow (it needs Tailscale too). The Mac's checklist is already
green, so nothing else changes. Copy in the sheet when one phone is already paired: "Pairing
another iPhone doesn't affect Arne’s iPhone."

**Second Mac, same phone.** Phone › Settings › Macs › **Pair Another Mac** opens the scanner
directly (no welcome, no Tailscale step). The second Mac runs its own checklist. The QR carries
the Mac's tailnet name (`t=`, see [Endpoints](#endpoints-and-fields-this-needs)); if it differs
from an already paired Mac's, the phone shows before pairing:

> MacBook Air is on a different tailnet from MacBook Pro.
> Your iPhone reaches one tailnet at a time, so only one of them will connect.
> [Pair Anyway] [Cancel]

**Replacing a phone.** A new phone pairs normally. The old one stays in the Mac's list with "last
seen 12 days ago" and Revoke. If the new device has the same name and model as one not seen for
24 hours, the confirm sheet adds a checkbox, on by default: "Remove Old iPhone (last seen 12 days
ago)".

### E. Re-pairing

| What happened | The phone sees | Copy | Action |
|---|---|---|---|
| Revoked on the Mac | 401 on any call | "MacBook Pro doesn't accept this iPhone any more. It was removed in Side A, or Side A was set up again." | **Pair Again** (scanner) |
| Remove Side A, or Side A set up on a new Mac (device list and TLS key are `ThisDeviceOnly`) | the pinned key no longer matches, or 401 | "MacBook Pro has a new security key, so this iPhone has to pair again." (key changed) / the 401 copy | **Pair Again** |
| Side A Remote deleted and reinstalled | Keychain items survive the delete; the App Group snapshot doesn't | "Side A Remote was paired with MacBook Pro before." | **Reconnect** (checks `GET /v1/hello` with the old token over the pinned key; `paired: true` restores it and re-registers push), **Start Over** (deletes the old token, pin and push key) |
| The Mac's tailnet address changed (rare: Tailscale keeps a machine's address unless it's removed and re-added) | no route to the stored address; Tailscale is up | "Can't reach MacBook Pro at its last address. If you re-added it to Tailscale, scan a new code." | **Scan New Code** |
| Removed on the phone (Settings › Macs › Remove This iPhone) | | Confirmation: "Remove this iPhone from MacBook Pro? You'll need to pair again to use it." | `DELETE /v1/devices/self`, or the relay's `DELETE /device` when the Mac is out of reach |

Pair Again sends `replaces: <old deviceID>` in `PairRequest`, so on confirm the Mac drops the
stale record instead of listing the same iPhone twice. A revoked record is already gone; the
field matters for reinstall and replacement. A key mismatch is never "accept the new key": the
phone treats it as a different machine until a new QR code or a new SAS confirmation says
otherwise.

## The Mac checklist

Settings > Remote, top of the tab while anything required is missing. Once Remote is on and a
phone is paired, the checklist collapses into the **Connection** section (one ✓ line each), and
any row that later fails reappears there with its fix.

Rows come from three sources:

| Source | Rows |
|---|---|
| `TailscaleStatus` (mac-server, `status --json` only) | Tailscale installed, running and signed in, iPhone on your tailnet |
| The listener and the system | Listening on the tailnet address, firewall |
| `DependencyCheck` (extended, see [Setup tab](#setup-tab)) and app state | tmux, Claude Code hooks, Codex hooks, staying reachable |

### Rows and copy

Icons follow `DependencyStatusView`: `checkmark.circle.fill` in secondary for ready, an empty
`circle` in `deckOrange` for the one to fix, a secondary empty circle for rows after it, a
`ProgressView().controlSize(.mini)` while checking. Buttons that leave Side A end in "↗".

**Required** (rows 1, 2 and 4 gate the switch; row 3 is shown in the same group but doesn't gate,
because a phone can be added to the tailnet after Remote is on)

| Row | State | Line | Button |
|---|---|---|---|
| 1 Tailscale installed | not found | "Tailscale isn't installed on this Mac." | **Get Tailscale ↗** (Mac App Store), secondary link "Standalone download ↗" (`tailscale.com/download/mac`) |
| | app present, no CLI that answers `version` | "Tailscale is installed, but its command line didn't answer." | **Check Again** |
| | ready | "Tailscale 1.90.2 · App Store" / "· standalone" / "· Homebrew" | |
| 2 Running and signed in | `stopped` | "Tailscale is off." | **Open Tailscale** |
| | `needsLogin` | "Sign in to Tailscale." | **Open Tailscale** |
| | ready | "Signed in as arne@example.com · tailnet arne.github" | |
| 3 iPhone on your tailnet | no iOS peer in `Peer` | "No iPhone on your tailnet yet." · "Install Tailscale on your iPhone and sign in as arne@example.com." | (none; the row turns green when one appears) |
| | iOS peer(s), all offline | "Arne’s iPhone is on your tailnet, but Tailscale is off on it." | |
| | ready | "Arne’s iPhone is on your tailnet · online" (or "2 iPhones on your tailnet") | |
| 4 Listening | Remote off | "Listens on 100.101.12.4:47800, your Mac's tailnet address, when Remote is on." | (the switch) |
| | port busy | "Port 47800 is in use by another app. Side A will use 47803." | **Use 47803** |
| | bind failed | "Side A couldn't listen on 100.101.12.4: <error>." | **Try Again**, **Copy Diagnostics** |
| | ready | "Listening on 100.101.12.4:47800 · reachable, checked just now" | |
| 4b Firewall (shown only when the macOS firewall is on and blocks Side A) | blocked | "The macOS firewall blocks incoming connections to Side A." | **Open Firewall Settings** (`x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall`) |

Row 3 is the Mac half of "same tailnet": iOS peers appear in `tailscale status --json` with
`OS: "iOS"`, their `HostName`, and `Online`. It's the one check the phone can't do for itself.

Row 4's address is `Self.TailscaleIPs[0]` (the IPv4 100.x address). The listener re-binds when it
changes (Tailscale restarted under a new identity) and the phone learns the new one through
`Hello.endpoints`. Binding needs no Tailscale feature beyond being connected.

Row 4b: when the Application Firewall is on, macOS asks "Allow incoming network connections?" the
first time Side A listens on a non-loopback address. If the user clicked Deny, `socketfilterfw
--getappblocked <Side A path>` reports it blocked; the row appears. Signed builds keep the
answer across Sparkle updates; ad-hoc builds may ask again after each build.

Installation type comes from the app bundle: `io.tailscale.ipn.macos` is the App Store build,
`io.tailscale.ipn.macsys` the standalone one (to confirm); a CLI under `/opt/homebrew` without the
app is Homebrew. All three work: Side A only reads `status --json` and binds an address.

**Recommended** (never gate the switch)

| Row | State | Line | Button |
|---|---|---|---|
| 5 Claude Code hooks | not installed, nothing paired | "Installs when you pair an iPhone." | |
| | not installed, paired (user removed them) | "Claude Code requests stay in the terminal." | **Install Hooks** (`setIsland(.claude, "on")`) |
| | Python missing | The `DependencyStatusView` Python row: "Install once: Python 3.9+" | **Install ↗** |
| | ready | "Claude Code hooks installed" | |
| 6 Codex hooks (hidden when Codex CLI isn't installed) | off | "Codex requests stay in the terminal." | **Turn On** (the same binding as the General tab's toggle) |
| | on, never heard from | "Run /hooks in Codex once and trust Side A's hooks." | **Copy /hooks** |
| | trusted | "Codex hooks trusted · last heard 3 min ago" | |
| 7 Staying reachable | Keep awake off | "Your Mac sleeps when idle, and your iPhone can't reach it asleep." | **Keep Awake Settings…** (Settings > General) |
| | on, lid option off, on a laptop | "Keeps awake while agents work. Closing the lid still sleeps it." | **Keep Awake Settings…** |
| | on battery and Also on battery off | "On battery. Your Mac sleeps as usual until it's on power." | |
| | ready | "Keeps awake while agents work · on power" | |

Row 7's footer, always shown, because Keep awake covers only working agents: "To start sessions
from your iPhone when nothing is running, also turn on System Settings › Battery › Options ›
Prevent automatic sleeping on power adapter when the display is off." with **Open Battery
Settings** (`x-apple.systempreferences:com.apple.Battery-Settings.extension`). Tailscale can't
wake a sleeping Mac; the copy never suggests "Wake for network access" because it doesn't help.

How row 6 knows: Codex keeps its trust decision to itself. Side A records `lastCodexHookAt` (in
`UserDefaults`) whenever any Codex hook message reaches the island socket. `Stop` fires at the
end of every Codex turn, so one finished turn after `/hooks` proves trust. Rewriting the hooks
(Python moved, a hook file edited) resets it to "never heard from".

**Optional**

| Row | State | Line | Button |
|---|---|---|---|
| 8 tmux (hidden if Side A bundles one) | missing | "Starting sessions and the terminal on iPhone need tmux 3.4 or later." | **Copy Install Command** (`brew install tmux`) |
| | too old | "tmux 3.2 is too old. Update to 3.4 or later." | **Copy Update Command** (`brew upgrade tmux`) |
| | ready | "tmux 3.5a" | |
| 9 Also on this Wi-Fi | off | "Also accept iPhones on this Wi-Fi, without Tailscale. Same pairing and encryption." | (toggle) |
| | on | "Also on Wi-Fi at 192.168.1.20:47800" | |

### Pairing sheet

The sheet from mac-server, with the transport above:

- **QR code** (`https://getsidea.com/pair#…`, everything in the fragment): tailnet address and port, LAN
  address when row 9 is on, the key's SPKI SHA-256 (`fp`), Mac name, Mac id, tailnet name and the
  8-character code. See [Endpoints](#endpoints-and-fields-this-needs). The sheet shows no code
  or address to type: pairing is QR-only.
- Instruction: scan it from Side A Remote, or with the iPhone camera once the app is installed.
- **Confirm, with the SAS.** After a right code, both devices derive the same 6 digits from both
  public keys, the pairing nonce and the code (protocol, Pairing) and show them:

  > Pair “Arne’s iPhone”?
  > iPhone 17 Pro · asked just now
  > Check that your iPhone shows **482 913**.
  > [Codes Don't Match] [Pair]

  Digits in SF Mono `.title`, `.monospacedDigit()`, grouped 3 + 3. Pair is not the default button
  and has no shortcut: matching is a check the user has to make, and a reflexive Return would skip
  it. VoiceOver reads the code digit by digit. **Codes Don't Match** declines (the phone gets 403
  `sas_mismatch`) and the sheet says: "Pairing stopped. Something between your iPhone and your
  Mac may not be what it seems. Start again, and if the codes differ again, pair on another
  network." With `replaces`, or the same-name rule from D, the checkbox line sits above the
  buttons.
- **After Pair:** "Paired. Arne’s iPhone is connecting…" then, when its first events socket opens,
  "Arne’s iPhone is connected." and the sheet closes after 1.5 s.
- **Demo** (`--demo`): the sheet shows a sample QR code and "The demo doesn't pair." in place of
  the instruction, like Keep awake's "The demo doesn't change power settings."

The SAS guards QR pairing. The QR code carries the key hash, so the phone pins it before sending
anything, and both screens then show the same 6 digits. A substituted key, or an agent that read
the code off the screen and raced the phone, changes them, so the user sees a mismatch before the
click mac-server already requires. (Typed-code pairing was removed after the security audit: a
man in the middle could grind its 6 digits offline.)

#### Code lifetime while installing

Each code still lasts five minutes and is single use. While the sheet stays open, an expired code
is replaced by a new one automatically, up to six times (30 minutes), with "New code" announced
to VoiceOver. After that: "Code expired." [New Code]. This lets a person install the app from the
camera's link without coming back to a dead code, without making any one code live longer.

### Setup tab

Settings > Setup is where Side A already says what is installed. Two additions, both reusing what
is there:

1. **A "Side A Remote" section first**, one line and one button:

   | State | Line | Button |
   |---|---|---|
   | nothing done | "Not set up" | **Set Up…** |
   | some required steps missing | "2 steps left" | **Continue…** |
   | ready, nothing paired | "Ready to pair" | **Pair iPhone…** |
   | paired | "Arne’s iPhone · connected now" / "· last seen 2 h ago" | **Open…** |
   | a row failing after setup | the failing row's line, e.g. "Tailscale is off." | **Fix…** |

   Every button sets `store.settingsTab = .remote`.

2. **Tools gains Tailscale and tmux rows**, by extending `DependencyReport` with `tailscale` and
   `tmux` (`Dependency` values, probed in `DependencyCheck.scan()` with the same bounded
   `--version` run; tmux reports through `-V`). They render through the existing row: checkmark
   and version, or **Install ↗** / **Update ↗**, and **Check Again**. They appear only once Remote
   has been opened, so people who never use Remote don't see tools they don't need.

   The Hooks section already lists Side A's hooks with a "Side A: Dynamic Island" chip. Hooks kept
   only for Remote (notch off) get "Side A: Remote".

### Arriving from a link

Side A registers the URL scheme `sidea` (new `CFBundleURLTypes` entry). `sidea://remote` and
`sidea://remote/setup` open Settings on the Remote tab. On the first visit through a link (the
website, or the phone's share link opened on the Mac via the guide), the guided tour overlay
draws its yellow ring once around the first unmet row's button with the note "Start here." and a
single **Got it**. It's the same `TourOverlay`, given a one-step list.

## The phone flow

Order: Welcome → Tailscale → Scan → Pairing (codes match, confirm on the Mac) → Sessions, with a
one-time notifications card and, after it, a one-time Live Activity card. This replaces ios-app
4.1's "Get your Mac ready" checklist (the Mac has the real one) and moves its Notifications step
out of onboarding.

### Welcome

- App icon, "Side A Remote", one line: "Your Mac's Claude Code and Codex sessions, on your
  iPhone."
- Three rows as ios-app specifies.
- **Pair with Your Mac** (`.glassProminent`), **Try a Demo** (`.glass`).
- Text button: "Don't have Side A on your Mac?" → [Get Side A for Mac](#b-phone-app-first-no-mac-app).
- Footnote: "Needs Side A on a Mac and Tailscale on both."

Opened from a scanned pairing link, the welcome is skipped and the app goes straight to Pairing.

### Tailscale

The phone can't read Tailscale's state. It can tell whether the app is installed
(`canOpenURL(tailscale://)`, with `tailscale` in `LSApplicationQueriesSchemes`, scheme to
confirm) and, after a scan, whether a route to the Mac's 100.x address exists.

| State | Copy | Buttons |
|---|---|---|
| Tailscale not installed | "Side A Remote reaches your Mac through Tailscale, a private network between your devices." · "Install it and sign in with the same account as your Mac." | **Get Tailscale** (App Store), **I've Installed It** |
| Installed | "Make sure Tailscale is on and signed in with the same account as your Mac." | **Open Tailscale**, **Continue** |

Then: "On your Mac, open Side A › Settings › Remote and click Pair iPhone." and **Scan Code**.
Coming back from the Tailscale app re-checks `canOpenURL`.

### Scan

- The scanner is ios-app's. Its title: "Scan the code on your Mac".
- Camera permission: the system prompt appears when the scanner first opens. Usage string
  (`NSCameraUsageDescription`): "Side A Remote uses the camera to scan the pairing code on your Mac
  and to take photos for a prompt."
- Denied: "Camera access is needed to pair." [Open Settings]. There is no other path: pairing is
  QR-only.
- Not a Side A code: a capsule under the frame for 2 s, "That isn't a Side A pairing code." The
  scanner keeps looking.
- **Local network permission** is asked only when the QR carries a LAN address and the tailnet
  address doesn't answer.
  `NSLocalNetworkUsageDescription`: "Side A Remote connects to Side A on your Mac over this Wi-Fi
  when Tailscale isn't on."

### Pairing

A glass card over the frozen camera frame with the Mac name from the QR and four steps in mono
`.footnote`, each turning into a ✓ as it passes:

```
Reaching MacBook Pro
Checking its security key
Check the code
Done
```

The first two run the first steps of the [connection test](#test-connection); a failure stops
there and shows its card. "Checking its security key" compares the server key with the QR's `fp`.
At "Check the code" the card says:

> On MacBook Pro, check that the code matches, then click Pair.
> **482 913**
> It shows this iPhone as “Arne’s iPhone”.

with a 60-second countdown in `.monospacedDigit()`. The phone shows no button of its own for
"match": the decision is made where the click is, on the Mac, so there is one place to get it
right. A **Cancel** text button stops pairing from the phone. The phone's name comes from
`UIDevice.current.name`, which needs the user-assigned device name entitlement; without it iOS
returns "iPhone", and the Mac shows "iPhone · iPhone 17 Pro". The wording works either way.

On success the card morphs into "Paired with MacBook Pro" and the Sessions tab appears behind it.
The pinned key hash is stored with the token in the shared keychain group.

### Failure cards

Calm full cards with one primary action, never alerts. Each names the device to act on.

| Detected | Copy | Actions |
|---|---|---|
| No route to 100.x, Tailscale not installed | "Side A Remote reaches your Mac through Tailscale." | **Get Tailscale** |
| No route, no VPN interface up (`NWPath` has no `.other` interface) | "Tailscale is off on this iPhone." | **Open Tailscale**, **Try Again** |
| No route, VPN up, QR tailnet differs from a paired Mac that answers | "This iPhone is on a different tailnet from MacBook Pro." · "Switch accounts in Tailscale, or sign in with the same account as your Mac." | **Open Tailscale**, **Try Again** |
| No route or timeout, VPN up | "Your iPhone can't reach MacBook Pro." · "Check that both are signed in to the same Tailscale account, and that the Mac is awake." | **Open Tailscale**, **Try Again** |
| Connect times out (5 s), route exists | "MacBook Pro isn't answering. It may be asleep, or the macOS firewall may be blocking Side A." · "If your tailnet uses access rules, they need to let this iPhone reach it." | **Try Again** |
| Connection refused | "MacBook Pro is on, but Side A isn't answering." · "Open Side A on the Mac and turn on Remote in Settings." | **Try Again** |
| TLS key doesn't match the QR's `fp` | "This isn't the Mac that showed the code." · "Something at this address answered with a different security key. Scan the code again on your own network." | **Scan Again** |
| TLS key changed for a paired Mac | "MacBook Pro has a new security key, so this iPhone has to pair again." | **Pair Again** |
| Not a Side A `Hello` | "Something other than Side A answers at this address." · "Check the address in Side A › Settings › Remote." | **Scan Again** |
| `Hello` protocol too old / too new | "Update Side A on your Mac to 0.6 or later." / "Update Side A Remote to pair with this Mac." | **Try Again** / **App Store** |
| `POST /v1/pair` 404 `no_pairing` | "Click Pair iPhone on your Mac first, then scan the new code." | **Scan Again** |
| 401 `bad_code` | "That code is no longer valid. Scan the code on your Mac again." | **Scan Again** |
| 410 `code_expired` | "This code has expired. Click Pair iPhone again on your Mac." | **Scan Again** |
| 403 `declined` | "Pairing was cancelled on MacBook Pro." | **Scan Again** |
| 403 `sas_mismatch` | "The codes didn't match, so pairing stopped." · "Start again on your Mac. If they differ again, pair on another network." | **Scan Again** |
| 408 `confirm_timeout` | "Nobody clicked Pair on MacBook Pro." | **Try Again** (re-posts the same code if it is still valid; a new TLS session gives a new SAS) |
| 429 | "Too many tries. Wait a minute and try again." | **Try Again** (disabled with a countdown) |
| Events socket refused after pairing | Not a card: pairing succeeds, the Mac chip says "Updates every 20 s", and Test Connection names the step | |

### After pairing: Sessions, then two cards

The done state is the real Sessions list, painted from the pairing response's `hello` and the
first snapshot. Above it, once, an inset row that leaves when acted on:

**Notifications card** (only while authorization is `.notDetermined`):

> Get requests on your Lock Screen
> Allow, deny or answer when a session needs you, without opening the app.
> [rendered sample: "Allow Bash · npm test" with Allow and Deny]
> [Turn On Notifications]  Not Now

Turn On requests `.alert, .sound, .badge, .timeSensitive`, registers for remote notifications and
posts `/v1/devices/push`. Not Now hides the card. It comes back once, the first time a request
arrives while the app is open, as a footer in the approval sheet: "Turn on notifications to get
this on your Lock Screen." [Turn On]. After that only Settings offers it. Denied later: Settings ›
Notifications shows "Notifications are off for Side A Remote." [Open Settings].

**Live Activity card** (after the notifications card is gone, and only when
`ActivityAuthorizationInfo().areActivitiesEnabled`):

> See your sessions at a glance
> One Live Activity for MacBook Pro: what's working, what needs you, and your tightest limit.
> [Show a Sample]  Not Now

Show a Sample starts a local activity with sample data for 15 s, labelled "Sample" in its leading
slot. Then: "Add the Limit or Sessions widget from your Home Screen." with no button (iOS has no
API to add a widget).

**Empty list:** "Nothing is running on MacBook Pro." · "Sessions appear here as they start." With
the `hosted` capability: **New Session**.

**Rows that come from the Mac's setup state** (`GET /v1/setup`, see [Endpoints](#endpoints-and-fields-this-needs)),
each a one-time dismissible row:

| Mac state | Row |
|---|---|
| Codex installed, hooks on, never heard from | "Run /hooks in Codex once on MacBook Pro to answer Codex requests here." |
| Codex hooks off | "Codex requests stay in the terminal. Turn them on in Side A › Settings › Remote." |
| Keep awake off | "MacBook Pro sleeps when idle, and then this iPhone can't reach it. Keep awake is in Side A › Settings › General." |
| tmux missing | Not a row. New Session explains it when tapped: "Starting sessions needs tmux 3.4 or later on MacBook Pro. Install it with brew install tmux." [Copy Command] |

## Diagnostics

Both apps have **Test Connection**. It walks the path from the outside in, stops at the first
failing step, and says what to do in plain words. Steps after the failure show "Not checked".
Every report has **Copy Report** (versions, states, timings, HTTP statuses, the first 8
characters of the pinned key hash; never tokens, hashes of tokens, keys or session content).

### Test connection: phone

Settings › Macs › MacBook Pro › **Test Connection**, also offered on every failure card and
connection banner as a text button.

| # | Step | How | Pass line | First failure says |
|---|---|---|---|---|
| 1 | Tailscale on this iPhone | a VPN interface is up and the 100.x address has a route | "Tailscale is on" | the matching route card above |
| 2 | Reaching the Mac | TCP connect to the stored address and port, 5 s | "Reached MacBook Pro in 38 ms · 100.101.12.4" | "MacBook Pro isn't answering. It may be asleep, or the macOS firewall may be blocking Side A." / refused: "MacBook Pro is on, but Side A isn't answering." |
| 3 | Security key | TLS handshake, SPKI hash equals the pinned one | "Security key matches the one from pairing" | "MacBook Pro has a new security key, so this iPhone has to pair again." [Pair Again] |
| 4 | Side A | `GET /v1/hello` | "Side A 0.6.1 · protocol 1 · Remote on" | "Remote is off in Side A on MacBook Pro." / the update copy |
| 5 | This iPhone | `GET /v1/state` with the token | "Paired as Arne’s iPhone" | "MacBook Pro doesn't accept this iPhone any more." [Pair Again] |
| 6 | Live updates | open the events socket on the same port, `hello`, wait 5 s for a snapshot or replay | "Live updates connected" | "Connected, but live updates are blocked." · "Update Side A on MacBook Pro, then try again." |
| 7 | Notifications on this iPhone | `UNUserNotificationCenter` settings | "Allowed · Time Sensitive on" | "Notifications are off for Side A Remote." [Open Settings] |
| 8 | Notifications from the Mac | `GET /v1/setup` push fields for this device | "MacBook Pro has this iPhone's push token" | "MacBook Pro can't reach the notification relay." / "MacBook Pro hasn't got this iPhone's push token yet." [Send Again] |
| 9 | Test notification | `POST /v1/diagnostics/push`, wait up to 20 s for the Service Extension's receipt in the App Group (or `willPresent` in the foreground) | "Test notification arrived in 1.2 s" | "MacBook Pro sent it, but it didn't arrive." · "Check Focus and Notification settings for Side A Remote." Relay results map: `gone` "Apple says this iPhone's push token is no longer valid. Open the app again to renew it."; `rejected` "The relay rejected it. Copy the report and send it to us." |
| 10 | Live Activities | `ActivityAuthorizationInfo` | "Live Activities on" | informational only: "Live Activities are off for Side A Remote." [Open Settings] |

With Wi-Fi pairing on, step 2 tries the tailnet address, then the LAN address, and the pass line
names which answered ("· over Wi-Fi").

The test notification is category `TEST`, no actions, body "Test notification from MacBook Pro."
It is collapsed by its id, so running the test twice leaves one.

### Test connection: Mac

Settings > Remote › Connection › **Test Connection**. The same ladder from the inside out, then
outward to the phones.

| # | Step | How | Pass line | First failure says |
|---|---|---|---|---|
| 1 | Tailscale | CLI `version` | "Tailscale 1.90.2" | checklist row 1 |
| 2 | Signed in | `status --json` | "Signed in as arne@example.com · tailnet arne.github" | checklist row 2 |
| 3 | Tailnet address | `Self.TailscaleIPs` | "This Mac is 100.101.12.4 on your tailnet" | "Tailscale hasn't given this Mac an address yet." |
| 4 | Listener | the bound socket's state | "Listening on 100.101.12.4:47800" | "Side A isn't listening. Port 47800 is in use by another app." |
| 5 | Security key | the Keychain identity loads and matches the hash in the last QR | "Security key ready · 3f9a1c2e…" | "Side A's security key couldn't be read. Make a new one; every iPhone pairs again." [Make New Key] |
| 6 | Reachable | from the Mac, TLS to its own tailnet address, pinned, then `GET /v1/hello` and an unauthenticated WebSocket upgrade (expects 401) | "Reachable at 100.101.12.4:47800" | "Side A can't reach itself on its tailnet address." · the firewall row's copy when `socketfilterfw` reports it blocked |
| 7 | iPhones on the tailnet | iOS peers in `status --json` | "Arne’s iPhone on your tailnet · online" | "No iPhone on your tailnet is online." (informational) |
| 8 | Hooks | settings files and `lastCodexHookAt` | "Claude Code hooks installed · Codex hooks trusted" | checklist rows 5 and 6 |
| 9 | Notification relay | `GET {relay}/v1/health`, then signed `GET /v1/installs/self` | "Relay reachable · 2 iPhones registered" | "Side A can't reach the notification relay. Notifications won't arrive; everything else works." |
| 10 | Each paired iPhone | last seen, open sockets | "Arne’s iPhone · connected now" | "Arne’s iPhone hasn't connected for 3 days." (informational) |

Step 6 runs from the Mac itself, so it proves the listener and the firewall answer for the
tailnet interface, not that a phone can route to it; step 7 and the phone's own test cover that.

Each paired iPhone row has **Send Test Notification**. Results: "Sent. Apple accepted it." then,
if that phone has a live socket and acknowledges within 20 s, "Arne’s iPhone received it."
Otherwise: "Arne’s iPhone confirms when Side A Remote next connects." `gone`: "Arne’s iPhone
stopped receiving notifications. Open Side A Remote on it to renew."

Copy Report goes through the existing **Copy diagnostics** (mac-server) with the test's lines
added.

## Website

### Home page

The Remote section relay-and-release plans (before `trust-strip`) gains one line under its
requirements: "New to it? Follow the setup guide." linking `/remote`. Its requirements line
becomes "Requires iOS 26+, Side A on a Mac, and Tailscale on both."

### `/remote` setup guide

`site/remote/index.html`, added to `rollupOptions.input` in `vite.config.ts` next to
`how/index.html`, using `src/style.css` and the existing header and footer. In `sitemap.xml`,
`public/index.md` and `llms.txt`. Same CSP; no third-party scripts. Screenshots are from the
demo data on both apps, `site/public/remote/*.webp` with `@2x` sources, `width`/`height` set, and
real `alt` text.

Content, in order:

1. **Title:** "Set up Side A Remote". Lead: "See and answer your Mac's Claude Code and Codex sessions
   from your iPhone, over your own Tailscale network." Requirements line: "Side A 0.6 or later on
   macOS 14+, Side A Remote on iOS 26+, and Tailscale on both, signed in to the same account."
   Buttons: **Get Side A** and **Open Settings › Remote** (see C), and the App Store badge.
2. **Steps**, an ordered list, each one sentence plus a screenshot placeholder:

   | Step | Text | Screenshot |
   |---|---|---|
   | 1 | "Install Tailscale on your Mac and your iPhone, and sign in to the same account on both." | `remote/step-1-tailscale.webp`: both devices signed in (our own drawing, no Tailscale marks beyond the name) |
   | 2 | "In Side A, open Settings › Remote. It checks your Mac and shows what's left." | `remote/step-2-checklist.webp`: the Mac checklist with one row to fix |
   | 3 | "Turn on Side A Remote, then click Pair iPhone." | `remote/step-3-pair-sheet.webp`: the pairing sheet with a sample QR code |
   | 4 | "Scan the code with your iPhone camera. Without the app, it opens the App Store first." | `remote/step-4-scan.webp`: the phone scanner |
   | 5 | "Check that both devices show the same 6-digit code, then click Pair on your Mac." | `remote/step-5-codes.webp`: the Mac's confirm sheet beside the phone's card, same digits |
   | 6 | "Optional: run /hooks once in Codex, and keep your Mac awake while agents work." | `remote/step-6-recommended.webp`: the Recommended rows |

   If macOS asks whether Side A may accept incoming connections, a note under step 3 says:
   "Click Allow. That's your iPhone connecting over Tailscale."
3. **If it doesn't connect:** the phone's failure cards as a definition list, the same copy, so a
   search for the exact sentence on screen lands here. Ends with "Both apps have Test Connection.
   It stops at the first step that fails and says what to fix."
4. **Privacy, short:** "Your sessions go between your iPhone and your Mac over Tailscale,
   encrypted with a key only your Mac holds and your iPhone checks. Notifications are encrypted
   on your Mac and pass through our relay unreadable." Link to `/privacy`.

### `/pair`

The target of the `https://getsidea.com/pair#…` form the Mac shows: `site/pair/index.html`. It must never see the pairing code or key:

- Everything is in the fragment, which browsers never send, but page scripts can read it. This
  page loads **no analytics** and no script that reads `location`, so nothing records it. A test
  in `site/tests/` fails the build if `pair/index.html` includes the analytics module.
- Content: "Get Side A Remote to finish pairing." App Store badge (or the TestFlight link from
  `release.mjs` before approval). "Then scan the code on your Mac again." A link to `/remote`.
- `site/public/.well-known/apple-app-site-association` with `applinks` for `/pair` only, plus the
  content-type rule in `vercel.json` and `_headers` (relay-and-release, Site).

## Wireframes

### Mac: Settings > Remote, not set up

```
┌ Remote ──────────────────────────────────────────────────────────┐
│ [ ] Side A Remote                                   (disabled)   │
│     See and answer your sessions from your iPhone, over          │
│     Tailscale. 1 step left.                                      │
│                                                                  │
│ Set up                                                           │
│  ✓ Tailscale 1.90.2 · App Store                                  │
│  ○ Sign in to Tailscale.                       [Open Tailscale]  │
│  ○ No iPhone on your tailnet yet.                                │
│    Install Tailscale on your iPhone and sign in as the same      │
│    account.                                                      │
│  ○ Listen on your tailnet address           After the step above │
│                                                                  │
│ Recommended                                                      │
│  ○ Claude Code hooks: installs when you pair an iPhone.          │
│  ○ Run /hooks in Codex once and trust Side A's hooks.            │
│                                                    [Copy /hooks] │
│  ○ Your Mac sleeps when idle, and your iPhone                    │
│    can't reach it asleep.               [Keep Awake Settings…]   │
│ Optional                                                         │
│  ○ Starting sessions and the terminal on iPhone need             │
│    tmux 3.4 or later.                  [Copy Install Command]    │
│  [ ] Also accept iPhones on this Wi-Fi, without Tailscale.       │
│                                                                  │
│ footer: Checks again on its own while this tab is open.          │
└──────────────────────────────────────────────────────────────────┘
```

### Mac: Settings > Setup, Remote section

```
┌ Setup ───────────────────────────────────────────────────────────┐
│ Side A Remote                                                    │
│     1 step left                                   [Continue…]    │
│                                                                  │
│ Tools                                                            │
│  ✓ Python 3.9+                                         3.13.1    │
│  ✓ Claude Code                                       2.1.296     │
│  ✓ Codex CLI is ready                                            │
│  ✓ Tailscale                                          1.90.2     │
│  ○ tmux                                           Install ↗      │
│ Storage …                                                        │
└──────────────────────────────────────────────────────────────────┘
```

### Mac: pairing sheet, then confirm with the code

```
┌───────────────────────────────────┐   ┌───────────────────────────────────┐
│ Pair iPhone                       │   │ Pair “Arne’s iPhone”?             │
│        ┌───────────────┐          │   │ iPhone 17 Pro · asked just now    │
│        │ ▓▓ ▓ ▓▓▓ ▓ ▓▓ │          │   │                                   │
│        │ ▓ ▓▓  ▓ ▓▓ ▓  │  QR      │   │ Check that your iPhone shows      │
│        │ ▓▓▓ ▓ ▓▓  ▓▓▓ │          │   │                                   │
│        └───────────────┘          │   │           482 913                 │
│ Scan with the iPhone camera. If   │   │                                   │
│ Side A Remote isn't installed     │   │ [✓] Remove Old iPhone             │
│ yet, the camera opens the         │   │     (last seen 12 days ago)       │
│ download page.                    │   │                                   │
│ Expires in 4:32                   │   │                                   │
│                        [Cancel]   │   │  [Codes Don't Match]     [Pair]   │
└───────────────────────────────────┘   └───────────────────────────────────┘
```

### Phone: welcome, Get Side A for Mac, Tailscale

```
 Welcome                     Get Side A for Mac          Tailscale
┌───────────────────────┐   ┌───────────────────────┐   ┌───────────────────────┐
│                       │   │ ‹                     │   │ ‹                     │
│        ┌─────┐        │   │ Get Side A for Mac    │   │ Tailscale             │
│        │ ◉   │        │   │                       │   │                       │
│        └─────┘        │   │ Side A Remote shows   │   │ Make sure Tailscale is│
│    Side A Remote      │   │ what Side A sees on   │   │ on and signed in with │
│ Your Mac's Claude Code│   │ your Mac. Install     │   │ the same account as   │
│ and Codex sessions,   │   │ Side A there first;   │   │ your Mac.             │
│ on your iPhone.       │   │ it's free.            │   │   [Open Tailscale]    │
│                       │   │ macOS 14 or later,    │   │                       │
│ ◎ See every session…  │   │ with Claude Code or   │   │ On your Mac, open     │
│ ◎ Answer requests…    │   │ Codex CLI.            │   │ Side A › Settings ›   │
│ ◎ Start a session…    │   │ ┌───────────────────┐ │   │ Remote and click      │
│ ┌───────────────────┐ │   │ │Send Link to My Mac│ │   │ Pair iPhone.          │
│ │Pair with Your Mac │ │   │ └───────────────────┘ │   │ ┌───────────────────┐ │
│ └───────────────────┘ │   │       Copy Link       │   │ │    Scan Code      │ │
│ ┌───────────────────┐ │   │  Try a Demo Meanwhile │   │ └───────────────────┘ │
│ │    Try a Demo     │ │   │                       │   │                       │
│ └───────────────────┘ │   │ When Side A is        │   │                       │
│ Don't have Side A on  │   │ running, come back    │   │                       │
│ your Mac?             │   │ and tap Pair with     │   │                       │
│ Needs Side A on a Mac │   │ Your Mac.             │   │                       │
│ and Tailscale on both.│   │                       │   │                       │
└───────────────────────┘   └───────────────────────┘   └───────────────────────┘
```

### Phone: pairing, a failure, done

```
 Pairing                     Failure                     Done (Sessions)
┌───────────────────────┐   ┌───────────────────────┐   ┌───────────────────────┐
│ (camera frame, dimmed)│   │                       │   │ (● MacBook Pro)    ⋯  │
│ ╭───────────────────╮ │   │        ⚠︎              │   │ Sessions              │
│ │ MacBook Pro       │ │   │ MacBook Pro isn't     │   │ ┌───────────────────┐ │
│ │ ✓ Reaching        │ │   │ answering.            │   │ │Get requests on    │ │
│ │   MacBook Pro     │ │   │                       │   │ │your Lock Screen   │ │
│ │ ✓ Checking its    │ │   │ It may be asleep, or  │   │ │[Allow Bash·npm t…]│ │
│ │   security key    │ │   │ the macOS firewall    │   │ │[Turn On Notific…] │ │
│ │ ◌ Check the code  │ │   │ may be blocking       │   │ │      Not Now      │ │
│ │   Done            │ │   │ Side A.               │   │ └───────────────────┘ │
│ │                   │ │   │ ┌───────────────────┐ │   │ NEEDS YOU             │
│ │ On MacBook Pro,   │ │   │ │     Try Again     │ │   │ ✋ side-a · Work      │
│ │ check that the    │ │   │ └───────────────────┘ │   │   Allow Bash          │
│ │ code matches, then│ │   │    Test Connection    │   │ WORKING               │
│ │ click Pair.       │ │   │                       │   │ ◉ api · Personal      │
│ │     482 913       │ │   │                       │   │   Running swift test  │
│ │ Cancel      0:52  │ │   │                       │   │                       │
│ ╰───────────────────╯ │   │                       │   │                       │
└───────────────────────┘   └───────────────────────┘   └───────────────────────┘
```

### Test connection: phone and Mac

```
 Phone                                  Mac (Settings > Remote › Test Connection)
┌─────────────────────────────────┐    ┌──────────────────────────────────────────────────┐
│ ‹  Test Connection              │    │ Test Connection                                  │
│ MacBook Pro                     │    │  ✓ Tailscale 1.90.2                               │
│  ✓ Tailscale is on              │    │  ✓ Signed in as arne@example.com                  │
│  ✓ Reached MacBook Pro in 38 ms │    │  ✓ This Mac is 100.101.12.4 on your tailnet       │
│  ✓ Security key matches the one │    │  ✓ Listening on 100.101.12.4:47800                │
│    from pairing                 │    │  ✓ Security key ready · 3f9a1c2e…                 │
│  ✓ Side A 0.6.1 · Remote on     │    │  ✓ Reachable at 100.101.12.4:47800                │
│  ✓ Paired as Arne’s iPhone      │    │  ✓ Arne’s iPhone on your tailnet · online         │
│  ✓ Live updates connected       │    │  ✓ Claude Code hooks · Codex hooks trusted        │
│  ✗ MacBook Pro sent it, but it  │    │  ✗ Side A can't reach the notification relay.     │
│    didn't arrive.               │    │    Notifications won't arrive; everything else    │
│    Check Focus and Notification │    │    works.                          [Try Again]    │
│    settings for Side A Remote.  │    │  – Not checked                                    │
│    [Open Settings]              │    │ iPhones                                           │
│  – Live Activities: not checked │    │  Arne’s iPhone · connected now                    │
│                                 │    │                     [Send Test Notification]      │
│ [Run Again]       Copy Report   │    │ [Run Again]                    [Copy Diagnostics] │
└─────────────────────────────────┘    └──────────────────────────────────────────────────┘
```

## Endpoints and fields this needs

Missing from [protocol](protocol.md) or [mac-server](mac-server.md), on top of the security
review's transport change (which both still describe as Tailscale Serve with a `ts.net`
certificate, two ports and `/v1/ws` on 443):

| Need | Proposed | Where |
|---|---|---|
| QR payload for the new transport | `https://getsidea.com/pair#v=2&a=100.101.12.4:47800[&l=192.168.1.20:47800]&fp=<SPKI SHA-256, base64url>&n=<Mac name>&m=<Mac id>&t=<tailnet name>&c=K7Q29XMD`. `u=`/`w=` go away (one port, same address for REST and WebSocket). `t` drives the "different tailnet" check | mac-server (Pairing), protocol |
| Short authentication string | Decided: a truncated hash of both public keys, the pairing nonce, the code and the TLS key hash each side saw (protocol, Pairing); no TLS exporter | protocol (Pairing), mac-server |
| SAS outcome | the Mac's confirm sheet sends Pair, Cancel or Codes Don't Match; the phone's `POST /v1/pair/{attemptID}/wait` returns 201, 403 `declined`, 403 `sas_mismatch` or 408 `confirm_timeout` | protocol (Errors), mac-server |
| The phone knowing the Mac's setup state | `GET /v1/setup` → `SetupStatus {claudeHooks: Bool, codexHooks: off \| unconfirmed \| trusted \| notInstalled, codexLastHeardAt?, tmux: ok \| missing \| tooOld, keepAwake: Bool, onPower: Bool?, relay: ok \| unreachable \| unregistered, push: {registered: Bool, lastResult?: ok \| gone \| retry \| rejected}}` (the last for the calling device) | protocol, new endpoint and type; capability `setup` |
| Test notification | `POST /v1/diagnostics/push` → `{id, relay: ok \| gone \| retry \| rejected \| unreachable}`; the phone acknowledges with `POST /v1/diagnostics/push/{id}/received` (or an `ack` message on the events socket). The Mac's own per-phone button uses the same path | protocol; mac-server |
| A `TEST` push category | relay allowlist: category `TEST`, `loc-key` `PUSH_TEST_FALLBACK` ("Test notification from Side A"), no actions | relay-and-release (Send) |
| The Mac checking its relay registration | signed `GET /v1/installs/self` → `{devices: [{deviceId, environment, lastResult}]}` | relay-and-release (Endpoints) |
| Address changes | `Hello.endpoints {tailnet: "100.101.12.4:47800", lan?: "…"}`. The phone stores them at pairing and updates them on every `hello` over the pinned key | protocol (`Hello`) |
| Key fingerprint in `Hello` | `Hello.keyID`: first 8 bytes of the SPKI hash, so Copy Report and the Mac's test can show which key is in use | protocol (`Hello`) |
| Reinstall and replacement | `PairRequest.replaces: String?` (old device id); the Mac removes that record on Pair | protocol; mac-server (Pairing) |
| Pairing errors the phone must tell apart | 404 `no_pairing` (no sheet open), 403 `declined`, 403 `sas_mismatch`, 408 `confirm_timeout`. Protocol's error table has neither 403 nor 408 | protocol (Errors) |
| Code auto-renewal while the sheet is open | up to six renewals, each code still five minutes and single use | mac-server (Pairing) |
| iPhones on the tailnet | `TailscaleStatus` parses `Peer[*].OS`, `HostName`, `Online` | mac-server (`TailscaleStatus`) |
| Firewall state | `socketfilterfw --getglobalstate` and `--getappblocked <path>`, read-only | mac-server (diagnostics) |
| Make a new key | a Settings > Remote action that replaces the identity and revokes every device (they must re-pair; their pins no longer match) | mac-server (Settings > Remote) |
| Codex trust signal | `Island` records `lastCodexHookAt` on any Codex hook message, persisted; reset when the hooks are rewritten | mac-server (Island changes) |
| Tailscale and tmux as dependencies | `DependencyReport.tailscale` and `.tmux`; Tailscale install type from the bundle id | `DependencyCheck` |
| Opening the Remote tab from outside | `sidea://remote`, `sidea://remote/setup` (`CFBundleURLTypes`), plus `SettingsTab.remote` (already in mac-server) | mac-server (Settings > Remote) |
| Tour step for existing users | `TourStep.remote`, anchored on the gear button; `tourSeenRemote` | `GuidedTour.swift`, `MenuPlayer.swift` |
| Phone name | the user-assigned device name entitlement, so `DeviceInfo.name` is the real name | ios-app (capabilities) |
| Detecting Tailscale on the phone | `tailscale` in `LSApplicationQueriesSchemes`; confirm the Tailscale iOS app registers that scheme | ios-app (4.1) |
| Local network | `NSLocalNetworkUsageDescription` only: Wi-Fi addresses come from the QR code. There's no Bonjour on either side, and no `NSBonjourServices` | ios-app, relay-and-release (Bundle ids) |

Inconsistencies found while writing this, to settle in the owning spec:

1. **Code length.** ios-app 4.1 says a 6-character code; mac-server and protocol say 8. It is 8
   everywhere; the 6 digits are the SAS, a different thing, and the copy never calls both "code"
   on one screen (the 8 characters travel only in the QR code; no screen shows them).
2. **Transport in the other specs.** remote.md, mac-server (Tailscale Serve, MagicDNS and HTTPS
   checks, ports 443/8443, `Host` allowlist by MagicDNS name), protocol (Conventions, `/v1/ws` on
   443), ios-app ("No ATS exceptions: Tailscale Serve gives a real ts.net certificate"; its
   HTTPS-not-enabled error card) and relay-and-release (pairing "over Tailscale HTTPS") all still
   describe Serve. The `Host` check also needs the tailnet IP, and ATS needs a pinning delegate on
   every connection, not only LAN.
3. **`Hello` shape.** relay-and-release shows `{protocol, minClientProtocol, app, capabilities:
   ["push.v1", …]}`; protocol shows `protocolVersion`, `minProtocol`, `maxProtocol`, and
   capability names without versions. Protocol should win.
4. **When the listener runs.** mac-server runs it only while Remote is on and a phone is paired or
   the pairing sheet is open. A phone checking before the sheet opens then gets "connection
   refused" and can only say "Side A isn't answering", the same as when Side A is closed. See open
   question 2.

## Changes to other specs

- **ios-app 4.1:** the "Get your Mac ready" checklist becomes the Tailscale screen above; the
  Notifications step moves out of onboarding to the post-pairing card; error cards take this
  file's table (the HTTPS-certificates card goes); pairing shows the SAS; welcome gains Try a Demo
  and "Don't have Side A on your Mac?"; Settings › Macs › Mac gains Test Connection; pairing is
  QR-only (no typed code).
- **mac-server, Tailscale Serve and Settings > Remote:** Serve set-up, teardown and the MagicDNS /
  HTTPS states go; the checklist above sits over the switch until required steps pass; the
  pairing sheet's QR, instruction, SAS confirm and renewal change as above; the Connection
  section gains Test Connection.
- **relay-and-release, Site:** the Remote section links `/remote`; `/pair` loads no analytics.
- **design.md, Settings:** when Remote ships, the tab list gains Remote, and Setup's description
  mentions Remote's section.

## Live checks

Added to [validation](../validation.md#live-checks) alongside mac-server's:

- A fresh Mac account with no Tailscale: rows 1, 2 and 4 turn green in order as Tailscale is
  installed and signed in and Remote is turned on, without reopening the tab; row 3 turns green
  when a phone signs in to Tailscale.
- macOS firewall on: the first listen asks; Deny shows row 4b and the phone's timeout card; Allow
  clears both.
- Scanning the pairing QR code with the Camera on a phone without the app opens `/pair`; installing
  from it and scanning again pairs, with the sheet having renewed its code meanwhile.
- `/pair` loaded with a fragment makes no network request other than its own assets.
- The SAS: both devices show the same digits; a proxy in the middle with its own key makes
  pairing fail at "Checking its security key"; Codes Don't Match stops it on both sides.
- Each phone failure card, produced for real: Tailscale off on the phone, phone on another tailnet,
  Mac asleep, firewall denying, Side A quit, Remote off, an expired code, Cancel on the Mac, no
  click for 60 s, Make New Key on the Mac (paired phone shows the new-key card).
- Delete and reinstall the phone app: Reconnect restores the pairing; Start Over leads to a clean
  pair that replaces the old record on the Mac.
- Test Connection on each side with the relay blocked (`/etc/hosts`): both stop at the relay step
  and nothing else breaks.
- VoiceOver through the checklist, the pairing sheet (digits read one by one), the phone
  onboarding and both test screens.

## Open questions

Decided (coordinator, after review): 1, the SAS is a truncated hash of both public keys, the
pairing nonce and the code, with no TLS exporter; 2, while Remote is on, `GET /v1/hello` answers
even with nothing paired; 3, "iPhone on your tailnet" stays advice only; 4, no reconnect after a
reinstall in v1 (a reinstall pairs again, and `replaces` or the same-name rule cleans up); 5, the
tour step shows only to new users, existing users see the Setup tab section with no pop-up; 7,
turning Remote on offers to turn on Keep awake. Still open: 6.

1. **TLS exporter on both platforms.** The SAS needs the same exported secret from Network.framework
   on macOS (server) and iOS (client). If either side can't export it, the fallback is hashing
   both public keys and the code (still catches a key swap, since the phone hashes the key it
   actually saw), but it should be checked first.
2. **Listening while unpaired.** Should Side A answer `GET /v1/hello` (and only that) whenever Remote
   is on, even with nothing paired and no sheet open? It would let the phone tell "Side A is
   closed" from "Remote is on, open Pair iPhone", at the cost of a TLS port always open to the
   tailnet.
3. **Row 3 as a gate.** "iPhone on your tailnet" is the commonest miss, but gating Remote on it would
   block people whose phone reaches the Mac through machine sharing (a different tailnet, which
   the Mac's peer list may not show). Kept as advice; confirm with sharing in practice.
4. **Reconnect after reinstall.** Offering Reconnect relies on keychain items surviving the app's
   deletion, which iOS does today but doesn't promise. Worth building, or should a reinstall
   always mean pairing again (and the Mac's same-name rule clean up)?
5. **Tour step for existing users.** Showing a one-step tour once to existing users is the most
   visible thing here, and design.md says no feature promotion. Is the Setup tab section plus
   release notes enough?
6. **Version floor.** The first Side A version with Remote (0.6 here) is a placeholder. No Tailscale
   version floor is needed any more.
7. **Keep awake as a requirement.** Row 7 is advice. Should turning Remote on also offer to turn on
   Keep awake (one checkbox in the switch's confirmation), since a sleeping Mac is the most likely
   "it doesn't work" report?
