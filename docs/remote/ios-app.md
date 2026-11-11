# Side A Remote: iOS app spec

The native SwiftUI app described in [the Remote plan](../remote.md). This file covers the phone
side only: platform, project, state, every screen, notifications and glanceable surfaces, visual
tokens, and build order. Wire shapes are [protocol](protocol.md)'s and this file only names
them; the setup journey and its copy are [setup](setup.md)'s; server, bridge and relay work are in
their own specs.

Status: built and shipping (Side A Remote 1.0.1). Where this spec and the code disagree, the code wins.

The bar: it should feel like an app Apple might ship next to Shortcuts or Find My. It should not
look like a web dashboard or a terminal in a costume. System components first, glass only on what
floats, content on plain backgrounds, and Side A's rules everywhere: one fact per line, real
numbers only, nothing destructive is ever an "Always", rows don't move under a finger.

---

## 1. Platform

### Deployment target: iOS 26.0, built with the iOS 27 SDK

- **Why not iOS 18.** The design relies on Liquid Glass: the floating tab bar with a separate
  Search tab (`Tab(role: .search)`), `tabBarMinimizeBehavior`, `tabViewBottomAccessory`,
  `glassEffect(_:in:)`, `GlassEffectContainer` with `glassEffectID` morphs, the `.glass` and
  `.glassProminent` button styles, `ToolbarSpacer`, scroll edge effects, and sheets that turn to
  glass at partial detents. Copying that look on iOS 18 means custom blur views, and they are
  exactly the "almost native" look the user dislikes. Supporting two visual systems would double
  the polish work on every screen.
- **Why not iOS 27.** iOS 27 came out last month. Developers update quickly, but a public App
  Store app shouldn't lock out people still on 26 for a handful of conveniences.
- **iOS 27 APIs, behind `if #available(iOS 27, *)`:** `toolbarMinimizeBehavior(.onScrollDown, for:
  .navigationBar)` in the transcript, `swipeActionsContainer()` for swipe actions on transcript
  rows in a `LazyVStack`, `alert(item:)` / `confirmationDialog(item:)`, `visibilityPriority` and
  `.topBarPinnedTrailing` in the session toolbar, and `toolbarVisibility(.hidden, for: .statusBar)`
  in the terminal. Each one needs a fallback that already looks finished on 26.
- **SDK 27 build note:** `@State` is a macro now. Never give a `@State` property both an initial
  value and an assignment in `init`. Declare it without a value and assign it once in `init`.
- `Packages/SideAProtocol` keeps `iOS 17` / `macOS 14` so the Mac app can use it. Only the app
  targets require 26.
- **Devices.** iPhone first. iPad runs the same app with `NavigationSplitView` (sessions in the
  sidebar, transcript in the detail column), and that comes for free from the size-class-aware
  root described in section 3. Landscape works everywhere and matters most in the terminal. No
  watchOS app; the Live Activity's `.small` supplemental family covers the Watch Smart Stack.

### Dependencies

| | Decision |
|---|---|
| **SwiftTerm** (MIT) | The terminal. Pin an exact version in `project.yml`. |
| **Markdown** | **Native.** Use `AttributedString(markdown:options:)` with `.full` interpretation. It returns `PresentationIntent` per run (headers, list items, block quotes, code blocks, tables, thematic breaks), and we walk that into our own SwiftUI block views. Inline runs (bold, italic, code, links, strikethrough) stay `AttributedString` inside `Text`. No package. If GFM tables or task lists turn out wrong in practice, switch the block parser to Apple's `swift-markdown` (Apache 2.0, cmark-gfm). It's Apple's, small and auditable, and stays an escape hatch, not a day-one dependency. |
| **Syntax highlighting** | None in M0–M2: monospaced text on a quiet fill already reads well. M3 adds a small regex tokenizer in-house (keywords, strings, comments, numbers) for Swift, TS/JS, Python, shell, JSON, diff. No JavaScriptCore highlighters (Highlightr and similar). |
| **QR scanning** | VisionKit `DataScannerViewController` (`recognizedDataTypes: [.barcode(symbologies: [.qr])]`) in a `UIViewControllerRepresentable`. No package. |
| **Crypto** | CryptoKit: X25519 key agreement at pairing, ChaCha20-Poly1305 for push payloads. |
| **Everything else** | Foundation (`URLSession`, `URLSessionWebSocketTask`), SwiftUI, WidgetKit, ActivityKit, AppIntents, UserNotifications, PhotosUI, LocalAuthentication. |

So the app adds exactly one third-party package, SwiftTerm, as `remote.md` intends.

---

## 2. Project

### Layout

```
apps/ios/
  project.yml                 XcodeGen; the .xcodeproj is gitignored
  Config/                     Base.xcconfig, Debug/Release, entitlements per target
  SideARemote/                app target
    App/                      SideARemoteApp, RootView, AppModel, deep links
    Features/
      Onboarding/  Sessions/  Transcript/  Composer/  Requests/
      NewSession/  Terminal/  Accounts/  Search/  Settings/  ImageViewer/
    Design/                   tokens, glyphs, LCD readout, rings, haptics
    Resources/                Assets.xcassets, AppIcon.icon, Localizable.xcstrings
  Shared/                     framework target SideARemoteShared (app + all extensions)
    Keychain/ AppGroupStore/ PushCrypto/ Intents/ Snapshot/ Formatting/
  NotificationService/
  NotificationContent/
  Widgets/                    widgets, Live Activity, Control Center controls
  Tests/                      unit (stores, markdown, pacing) and UI snapshot tests
```

### Targets

| Target | Type | Bundle id | Notes |
|---|---|---|---|
| `SideARemote` | application | `com.arnenoori.sidea.remote` | Depends on SideARemoteKit, SideARemoteShared, SwiftTerm. |
| `SideARemoteShared` | framework | `…remote.shared` | Keychain, App Group snapshot, push decryption, App Intents and entities, formatters (percent, countdown, "12 min ago"). Linked by every target so intents work in widgets, the Live Activity and Siri. Ships an `AppIntentsPackage`. |
| `NotificationService` | app extension | `…remote.NotificationService` | Decrypts payloads, sets category, thread and interruption level, updates the widget snapshot. |
| `NotificationContent` | app extension | `…remote.NotificationContent` | SwiftUI UI for `QUESTION`, `PLAN` and `REQUEST*`. `UNNotificationExtensionUserInteractionEnabled = YES`. |
| `SideARemoteWidgets` | widget extension | `…remote.Widgets` | Home and Lock Screen widgets, `ActivityConfiguration`, `ControlWidget`s. |

### Shared capabilities

- **App Group** `group.com.arnenoori.sidea.remote`: `shared.sqlite` (WAL), the one store every
  process writes: the outbox, the widget snapshot (paired Macs, counts, top waiting request,
  accounts' tightest limits, `updatedAt`) and the decrypted request cache the Service Extension
  fills. Every read-modify-write is one short `BEGIN IMMEDIATE` transaction, never held across an
  `await` or into suspension (protocol, Outbox). The transcript page cache stays under
  `Library/Caches` (app only).
- **Keychain access group** `$(AppIdentifierPrefix)com.arnenoori.sidea.remote.shared`, items
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: per Mac the device token, the pinned key
  hash, the push key and `keyID`, the relay install id, `deviceID` and `deviceSecret`. Notification
  actions and Live Activity buttons that the gate allows on a locked phone work after first
  unlock.
- Push Notifications (with Time Sensitive), Background Modes: `remote-notification`,
  `NSSupportsLiveActivities` + `NSSupportsLiveActivitiesFrequentUpdates` (only for the burst after
  a request arrives), Face ID usage string, Camera usage string ("to scan the pairing code shown
  on your Mac"), `NSPhotoLibraryAddUsageDescription` ("to save images from a session"), Photos
  picker needs no permission.
- **Pinned TLS on every connection.** Side A presents its own self-signed key; one
  `URLSessionDelegate` (shared by REST and `URLSessionWebSocketTask`) evaluates
  `NSURLAuthenticationMethodServerTrust` by comparing the SPKI SHA-256 with the Mac's pinned hash
  and accepts nothing else, on the Tailscale address and the LAN alike. No ATS exception is
  planned (protocol open question 5 checks this for IP-literal hosts).
- The user-assigned device name entitlement, so `DeviceInfo.name` is "Arne's iPhone", not
  "iPhone" (setup). `SideAPushEnvironment` per build configuration (relay-and-release).
- `project.yml` sets `SWIFT_VERSION 6`, strict concurrency complete, `SWIFT_DEFAULT_ACTOR_ISOLATION
  = MainActor` on the app target (not on the Kit package), `ENABLE_PREVIEWS`, and String Catalogs.

---

## 3. State architecture

### Layers

```
SideARemoteKit (package)                       SideARemote (app)
┌────────────────────────────┐                 ┌───────────────────────────────────────┐
│ RemoteClient  (REST, async)│                 │ AppModel  @Observable @MainActor       │
│ EventSocket   (/ws/events) │  RemoteState    │  ├ macs: [MacID: MacConnection]        │
│ SyncEngine    actor, 1/Mac │ ─AsyncStream──▶ │  ├ sessions: SessionsStore             │
│  ├ seq + gap repair        │                 │  ├ requests: RequestsStore             │
│  ├ outbox (idempotent)     │ ◀─commands───── │  ├ transcripts: TranscriptStore (LRU)  │
│  └ snapshot persistence    │                 │  ├ accounts: AccountsStore             │
│ TermSocket   (/ws/term)    │                 │  ├ hosted, projects                    │
└────────────────────────────┘                 │  └ images: ImageCache                  │
                                               └───────────────────────────────────────┘
```

- **One `SyncEngine` actor per paired Mac** (protocol, Client sync). It owns the REST client, the
  events socket, the last sequence number, the outbox and reconnect, and exposes
  `updates: AsyncStream<RemoteState>`: whole value-typed states, coalesced to at most one every
  16 ms. Transcripts come from its `TranscriptFeed`s the same way (`AsyncStream<TranscriptWindow>`).
  It holds no view state.
- **Stores are `@Observable @MainActor` classes** that consume `RemoteState` and diff it into their
  own properties, so a store only publishes the parts that changed. Views read stores and never
  the engine. Each store keys everything by `(MacID, id)`. Views call intent methods on stores
  (`requests.answer(id, .allow)`), and the store forwards a command to the right engine.
- **`AppModel`** is created once in `SideARemoteApp` and injected with `.environment(model)`.
  Sub-stores are properties, so a view that reads only `model.accounts` re-renders only when
  accounts change (Observation tracks per property).
- **Optimistic answers.** `answer` marks the request `answering` at once (the sheet closes with a
  success haptic), the outbox posts with the request id as the idempotency key, and a 409 becomes
  `answeredElsewhere` ("Answered on Mac"). A network failure keeps it in the outbox and the row
  shows "Sending…", then "Not sent. Retry". A 409 `outcome_unknown` (Side A restarted mid-action)
  shows "May not have reached MacBook Pro" with the session to check and a Retry that sends a new
  key. It never silently drops and never retries an ambiguous action by itself.
- **Transcripts** follow Paseo's model: the stream is for speed, the paged fetch is the truth.
  `TranscriptStore` keeps the eight most recent sessions in memory, caches pages on disk
  (`Caches/transcripts/<mac>/<session>/`), and opens at the latest message from cache before the
  network answers. Gaps are repaired by the feed with the opaque `after` cursor (protocol,
  Transcript gap repair).
- **Paint from the last copy.** On launch, stores load the App Group snapshot and disk caches
  synchronously, so the first frame shows real content with an age, never a spinner.

### Connection states (per Mac)

| State | Meaning | Shown as |
|---|---|---|
| `connecting` | first attempt after launch | nothing for 600 ms, then a quiet "Connecting…" in the Mac chip |
| `live` | socket open, seq current | green dot on the Mac chip |
| `reconnecting(since:)` | socket dropped, backoff 0.5 s doubling to 30 s with ±20 % jitter (protocol); immediate retry on foreground and on network change | chip: "Reconnecting…"; content stays, with `Updated 2 min ago` once older than 60 s |
| `offline(.tailscaleOff)` | no VPN interface up and no relay route, or no route to the Mac's 100.x address | banner: "Tailscale is off on this iPhone", button **Open Tailscale** (`tailscale://`, App Store fallback) |
| `offline(.macUnreachable)` | Tailscale up, Mac doesn't answer | banner: "Can't reach MacBook Pro. It may be asleep or Side A is closed." |
| `offline(.revoked)` | 401 | full-screen state on that Mac: "This iPhone was removed from MacBook Pro", **Pair again** |
| `offline(.keyChanged)` | the TLS key doesn't match the pin | "MacBook Pro has a new security key, so this iPhone has to pair again." **Pair Again**; no token is sent |
| `offline(.macAsleep)` | the Mac's `bye` said `sleep`, until it next answers | "MacBook Pro is asleep" |
| `offline(.relayRefused)` | no address answered and the relay refused this phone, three rounds running | the relay's refusal, **Pair Again** |
| `offline(.incompatible(installed:))` | `/hello` says the Mac's protocol is too old; no field names a minimum version, so the copy gives only what's installed | "Update Side A on MacBook Pro from 0.5.43 to use it with this iPhone" |

Rules: banners sit under the navigation bar as an inset grouped row, never as a toast, and never
cover content. Stale data stays visible with its age and is never greyed out (Side A rule: a
stale reading says how old it is). Actions that need the Mac (Allow, Send) stay enabled while
reconnecting and go to the outbox. While offline they're disabled with the reason as the
accessibility hint. Foreground return and `NWPathMonitor` changes trigger an immediate reconnect
and reset backoff. Every banner offers **Test Connection** (setup, Diagnostics).

### Several Macs

- Pairing adds a `MacConnection`. Most people have one Mac, and with one Mac the Mac never appears
  as a header anywhere.
- With two or more: Sessions groups by Mac first (section header: Mac name + status dot),
  Accounts groups by Mac (accounts are per Mac), and New session asks which Mac in its first
  chip. Notifications put the Mac name in the subtitle. One Live Activity per Mac with something
  running (ActivityKit allows several).
- The leading toolbar Mac chip on Sessions shows "2 Macs" and opens the Macs sheet.

### Navigation and deep links

- `RootView`: `TabView` with `Tab("Sessions")`, `Tab("Accounts")`, `Tab(role: .search)`. Each tab
  owns a `NavigationStack(path:)` with a typed `Route` enum (`session(MacID, SessionID)`,
  `account(…)`, `terminal(…)`, `settings`, …). In regular width the Sessions tab becomes a
  `NavigationSplitView`.
- URL scheme `sidea-remote://` and `onOpenURL` / `NSUserActivity` for: `session/<mac>/<id>`,
  `request/<mac>/<rid>` (opens the session with the approval sheet), `new`, `pair?…` (the QR
  payload is also a universal-link-shaped URL so the system Camera can open it).
- Notification taps, widget taps, Live Activity taps, Spotlight and App Intents all resolve to a
  `Route` through one `Router.open(_:)`.

---

## 4. Screens

Shared conventions for every screen:

- **Dynamic Type** to AX5. Rows that put two facts side by side switch to stacked at
  `dynamicTypeSize.isAccessibilitySize`. Mono metadata scales with `.footnote`. The terminal
  ignores Dynamic Type (it's a grid) but supports pinch to resize.
- **VoiceOver:** every row is one element with a composed label in reading order ("side-a, needs
  you, Allow Bash: npm test, Claude on Work account"), and secondary actions are
  `accessibilityActions`, not hidden buttons. Status glyphs are never the only signal; the label
  says the state.
- **Reduce Motion:** springs become 0.2 s opacity cross-fades, zoom transitions become fades,
  the spinner glyph becomes a static three-dot glyph, streaming text appears in chunks.
- **Reduce Transparency / Increase Contrast:** system glass adapts automatically. Our custom
  fills use the high-contrast variants in the asset catalog.
- **Haptics** come from `.sensoryFeedback`, tied to state changes, never fired imperatively from a
  button action when a state-driven trigger exists.

### 4.1 Onboarding and pairing

The journey, its states and all its copy are [setup](setup.md#the-phone-flow)'s: Welcome →
Tailscale → Scan → Pairing (codes match, confirm on the Mac) → Sessions, with the notifications
and Live Activity cards after pairing, not during it, and setup's failure-card table (there is no
"HTTPS certificates" card: the tailnet needs no HTTPS or MagicDNS). The wire is protocol's
Pairing. This section keeps the visual design of each screen.

**Welcome.** Plain `systemBackground`. Centered app icon at 96 pt (the real icon, not a
redraw), title "Side A Remote" (`.largeTitle.bold`), one line "Your Mac's Claude Code and Codex
sessions, on your iPhone." Below, three feature rows (SF Symbol in a 28 pt
`secondarySystemFill` circle + one line each): "See every session, on every account", "Answer
requests from the Lock Screen", "Start a session from anywhere". Bottom: `.glassProminent`
full-width **Continue** button, and setup's Try a Demo and "Don't have Side A on your Mac?" under
it. Reference: Apple's own "What's New" sheets; no carousel, no illustrations.

**Scanner.** Full-screen camera (`DataScannerViewController`, no highlight overlay drawn by
VisionKit). A 260 pt rounded square (radius 36, continuous, white 2 pt stroke at 80% opacity)
with the surroundings dimmed 45%. Title above in white `.title3.semibold` "Scan the code on your
Mac". Glass close button top left, glass torch toggle top right. Pairing is QR-only: there is no
typed-code path. On detection the square snaps to the code's bounds with a spring (damping 1.0,
response 0.3), a `.success` haptic plays, and the camera freezes on that frame while pairing.
(Reference: Meetup's rounded scan frame.) Camera denied: "Camera access is needed to pair." with
an **Open Settings** button and no other path.

**Pairing.** Over the frozen frame: a glass card with the Mac name from the QR and setup's four
steps in mono `.footnote` ("Reaching MacBook Pro · Checking its security key · Check the code ·
Done"). At "Check the code" the card shows the **six-digit comparison code** in SF Mono
`.largeTitle`, grouped 3 + 3 (`482 913`), `.monospacedDigit()`, read digit by digit by VoiceOver,
with "On MacBook Pro, check that the code matches, then click Pair." and a 60-second countdown. The
phone has no Match button: the decision is made on the Mac. Success: the card morphs (shared
`glassEffectID`) into "Paired with MacBook Pro" with a green checkmark, then the Sessions tab
appears behind it. The token, the pinned key hash, `deviceSecret` and the push key go into the
shared keychain group.

**Failures** use setup's table, each a calm full card with a primary action, never an alert.

**Codex note.** When `GET /v1/setup` reports Codex hooks installed but never heard from, Sessions
shows a one-time row: "Run /hooks in Codex once on MacBook Pro to answer Codex requests here."

### 4.2 Sessions (home)

**Layout.** `NavigationStack`, large title "Sessions", `List` with `.insetGrouped` style.

- **Toolbar leading:** the Mac chip, a glass capsule: green 6 pt dot + "MacBook Pro" in
  `.subheadline.weight(.medium)`. States: green (live), grey hollow (reconnecting, with a
  three-dot glyph), red hollow (offline). Tap opens the Mac sheet: status with the path ("Connected
  via Wi‑Fi", "via Tailscale", "via Relay"), last seen, power,
  memory, Keep Awake, Quit Idle, Clean Up, add a Mac (section 4.14).
  Reference: ChatGPT Codex's Mac with a green dot.
- **Toolbar trailing:** `square.and.pencil` (New session), then `ellipsis.circle` menu: Group by
  (Project / Account / None), Show idle sessions. Settings is its own tab.
- **Bottom accessory** (`tabViewBottomAccessory`): only while one or more requests wait and the
  user isn't on that session. A glass capsule: amber dot, "Allow Bash · npm test", trailing
  "+2" when more wait. Tap opens the approval sheet. The tab bar never minimizes on scroll
  (`tabBarMinimizeBehavior(.never)`): minimized, it split into two pieces. If the SDK can't hide the accessory cleanly when nothing
  waits, use a `safeAreaInset(edge: .bottom)` glass capsule with the same look.

**Sections, in order** (Side A's order: what needs you first):

1. **Needs you**: sessions with an open request, question or plan. Header in amber text.
2. **Working**: running sessions, fixed order (newest started first within project), so rows
   don't move under a finger. Order changes are held while a touch is down or the list is
   scrolling, then applied with a fade.
3. **Ready**: finished and waiting for a follow-up (Side A's Ready list).
4. **Idle**: folded by default behind a "6 idle sessions" disclosure row; grouped by project
   when expanded.

With "Group by Project", each section groups rows under quiet project subheaders (`.footnote`
semibold, secondary, folder glyph), following ChatGPT Codex's projects-as-folders.

**Session row** (min height 64, insets 16/12):

```
 [◉]  Fix the flaky sync test                            2m
      side-a · Work · claude-opus                    (mono, secondary)
      Running npm test                                (mono, tertiary)
```

- Leading 22 pt **status glyph** (section 7.6): amber filled ring for needs you, an animated arc
  for working, green check for ready, hollow circle for idle; the agent glyph (`asterisk` for
  Claude, `chevron.left.forwardslash.chevron.right` for Codex) sits as a 10 pt badge at its
  lower right, and a `terminal` badge joins it for hosted sessions.
- Line 1: title (`.body.weight(.semibold)`, 1 line, tail truncation), trailing elapsed time or
  "now" (`.footnote.monospacedDigit()`, secondary).
- Line 2: `project · account · model` in `.footnote.monospaced()` secondary (Perplexity-style mono
  metadata line).
- Line 3: current step, or for needs-you rows the request headline in amber text ("Allow Bash ·
  npm test"). One fact. A flag (stuck, looping, failing) replaces the step with a triangle glyph,
  and only "failing" is red.
- Line 3 also carries, trailing, the session's listening ports and memory in mono tertiary
  (`:3000 · 1.4 GB`), and a waiting message or stop ("Message waiting", "Stops after this step").
- **Swipe actions and context menu** (preview: the last assistant message) by row state: the
  table at the end of section 4.14. In short: Allow / Reply / Note / Continue on iPhone leading;
  Stop, Take Back, Quit, Open Terminal trailing; the context menu adds Send a Message…, Interrupt
  Now, Preview :port, Stop Server…, Restart Fresh…, Quit Session…, Copy Session ID. Continue on
  iPhone (only when idle or waiting and not hosted) confirms that it closes the Mac tab.

**States.**

- *Empty (connected, nothing live):* `ContentUnavailableView` with the disc glyph, "No sessions
  running", "Start one here or in a terminal on MacBook Pro.", button **New Session**.
- *First load with no cache:* redacted placeholder rows (`.redacted(reason: .placeholder)`) for
  at most 1 s, then the real state. Never a centered spinner.
- *Stale:* content stays; the banner row "Updated 4 min ago · Reconnecting…".
- *Offline:* banner per section 3 at the top of the list, content below with its age.
- *Not paired:* onboarding.

**Interactions.** Pull to refresh forces a snapshot. New rows fade and slide 8 pt in (spring
damping 1.0, response 0.35); removed rows fade. When a request arrives while the app is in the
foreground: `.warning` haptic, the row moves into Needs you (the only time a row moves, and only
when no touch is down), and VoiceOver posts an announcement "side-a needs you: Allow Bash".

**Accessibility.** Custom rotor "Needs you" jumps between pending rows. Each row's label: title,
state, request or step, project, account, agent, elapsed.

```
┌─────────────────────────────────┐
│ (● MacBook Pro)         ✎   ⋯   │
│ Sessions                        │
│                                 │
│ NEEDS YOU                       │
│ ┌─────────────────────────────┐ │
│ │ ◎* Fix the flaky sync test 2m│ │
│ │    side-a · Work · opus      │ │
│ │    Allow Bash · npm test     │ │ ← amber
│ └─────────────────────────────┘ │
│ WORKING                         │
│ ┌─────────────────────────────┐ │
│ │ ◠* Ship 0.5.37         14m   │ │
│ │    side-a · Personal · opus  │ │
│ │    Editing Island.swift      │ │
│ ├─────────────────────────────┤ │
│ │ ◠<> Add LAN mode        3m   │ │
│ │    remote · Team · gpt-5     │ │
│ │    Running swift build       │ │
│ └─────────────────────────────┘ │
│ READY                           │
│ ┌─────────────────────────────┐ │
│ │ ✓* Write the iOS spec   now  │ │
│ └─────────────────────────────┘ │
│ ▸ 6 idle sessions               │
│                                 │
│  ( ● Allow Bash · npm test +2 ) │ ← bottom accessory
│ ╭───────────────────────╮ ╭──╮  │
│ │ Sessions   Accounts   │ │⌕ │  │ ← glass tab bar
│ ╰───────────────────────╯ ╰──╯  │
└─────────────────────────────────┘
```

### 4.3 Session detail (transcript)

References, with what each one gives us:

| Reference | Take |
|---|---|
| v0 transcript ([Mobbin](https://mobbin.com/screens/f4489226-373f-42bf-9839-26105c144eff)) | Plain full-width prose; tool steps as quiet one-line rows with a leading glyph, a past-tense label and a trailing chevron; "Thought for 1s" as just another row |
| v0 running turn ([Mobbin](https://mobbin.com/screens/e180ae62-64e2-40eb-a851-dba120707fba)) | The live row says what it is doing now ("Thinking") and becomes its past tense when done |
| v0 scroll-to-bottom ([Mobbin](https://mobbin.com/screens/e31ba8b6-bb5d-4c43-9295-7c7638dcff7a)) | A glass circle that floats over the blurred content just above the composer |
| v0 console ([Mobbin](https://mobbin.com/screens/6f8c4407-8d0f-4d5c-9cb0-f46e4f89a152), [filter menu](https://mobbin.com/screens/99110047-5d5c-4046-9be2-3ae0c6e22b42)) | Bash output as a full-height log page with Copy all at the bottom |
| Grok thinking ([live](https://mobbin.com/screens/74b4af91-f638-47a0-84dc-3ead3cae2577), [live with steps](https://mobbin.com/screens/bc2aecf1-1fb2-4216-901c-164499e66f4e), [done](https://mobbin.com/screens/1894e202-3b40-4a05-a2fe-bb44c70aa38d)) | "Thinking · 2s" with an animated glyph and a ticking count; while live the latest thought lines show under it; when done it folds to one quiet "Thoughts ›" row |
| Grok turn end ([Mobbin](https://mobbin.com/screens/172f9754-b3d1-4e8a-b7f0-3b07b072bdf6)) | A row of small icon actions under the last reply, with the model and the duration trailing in tertiary |
| Granola chat ([Mobbin](https://mobbin.com/screens/77c50532-d6fa-4077-958a-d4a33e5e5edf)) | "Thought for 1s ›" in tertiary text with no icon weight; a centered arrow over the content to jump down |
| Dot ([Mobbin](https://mobbin.com/screens/d603ac4a-63af-4177-83b3-4818292d0302)) | Centered date separators ("Yesterday at 3:06 PM") between turns far apart in time; image attachments sit above the user bubble |
| Grok Bot chat ([Mobbin flow](https://mobbin.com/flows/1e2f749a-8054-47cd-9049-f267dc34d362)) | The file chip (icon, name with a dimmed extension, size), the inline question card with lettered options, and the floating glass back button and title |

What we don't take: Grok Bot's grey cards around every assistant paragraph (prose stays plain,
as in v0, so cards keep meaning "an object": a diff, a file, a question), and v0's avatar beside
the user bubble (every user turn on this phone is the same person, so the avatar is a repeated
non-fact; the bubble keeps the width instead).

**Layout.** Content is a `ScrollView` + `LazyVStack(spacing: 0)` on `systemBackground`, with
`defaultScrollAnchor(.bottom)` and a `ScrollPosition` keyed by message id. The composer is pinned
with `safeAreaBar(edge: .bottom)` (iOS 26), so the soft scroll edge effect blurs text under it
the way v0's does. The top edge uses the same soft edge effect under the navigation bar. iOS 27:
`toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)`.

**Navigation bar.** The system bar, which iOS 26 already draws as floating glass over content
(the look of Grok Bot's back button and title pill, without building either). Title: the session
title, 1 line; `navigationSubtitle` `side-a · Work · opus` in mono. The title gets a
`toolbarTitleMenu`, so tapping it opens a system menu: Rename…, Pin / Unpin, Session Info. Session
Info is a sheet (medium / large) with everything the Mac knows about the session: status and how
long, the health flag, account and model, context size, ports and memory, branch and worktree,
the conversation id (copyable mono).

**Toolbar.** Trailing: `terminal` (hosted only; opens Terminal), then an `ellipsis.circle` menu
in sections:

- Steer: Send a Message…, Stop Before Next Step, Interrupt Now (hosted), Take Back (only while a
  message or stop waits).
- Session: Restart Fresh…, Continue on iPhone, Quit Session….
- Ports (only while the session listens): Preview :3000, Stop Server on :3000….
- Share: Copy Transcript as Markdown, Share, Show on Mac.

With iOS 27 the terminal button is `.topBarPinnedTrailing` and the rest overflow. Section 4.14
says what each action does.

**Message anatomy.**

- **Top fold:** "18 earlier messages" as a centered secondary capsule (Codex reference). Tap
  loads the previous page with `before=` and keeps the scroll position on the current first
  message.
- **Date separator** (Dot): when two turns are more than 30 minutes apart, a centered `.caption`
  tertiary line between them: "Yesterday at 3:06 PM".
- **User turn:** right-aligned, max 80% width, `secondarySystemFill` rounded rect radius 20,
  `.body`. Pasted images show as 64 pt thumbnails above the bubble, right-aligned (Dot, v0). No
  avatar, no tail.
- **Assistant text:** full width, no container (v0), `.body` with line spacing 3. Blocks:
  paragraphs (12 pt after), headings (`.title3.bold` / `.headline` / `.subheadline.semibold`,
  20 pt before), lists with hanging indent, block quotes with a 3 pt `separator` bar, thematic
  break as a hairline, tables as a horizontally scrolling grid (`Grid`) with a hairline header
  rule. Inline code: SF Mono at 0.92 size on `tertiarySystemFill`, radius 4. Links: label color,
  underlined, open in `SFSafariViewController`, and local paths (`/Users/…`) render as mono, not
  links. Text is selectable (`.textSelection(.enabled)`) per block.
- **Tool row** (v0): one line, 44 pt min height (a full touch target), no container:
  `[glyph 15pt secondary]  Read Island.swift                 0.4s  ›`. The label is a past-tense
  sentence in `.subheadline` secondary: the verb in `.weight(.medium)`, the target in
  `.monospaced()` for paths and commands, middle truncation for paths. Verbs: Read, Edited, Wrote,
  Ran, Searched, Listed, Fetched, Searched the web, Asked a subagent, Used `<mcp tool>`. While the
  step runs the label is present tense ("Running swift test") and the glyph plays
  `.symbolEffect(.variableColor.iterative)`; when it ends the label swaps with
  `.contentTransition(.opacity)`. Trailing: the duration in mono tertiary (from 1 s up), the
  chevron in tertiary, or a red `xmark.circle.fill` instead of the duration on error. **Tap opens
  the step's own page with a zoom transition out of the row** (section 6.2); drag it down or swipe
  from the edge to send it back into the row. Glyphs per tool in section 7.6.
- **Tool step page** (the zoom destination): a pushed page with the row's glyph and label as its
  inline title, content by tool: Bash is v0's console (the command in a mono block, then the output
  as a selectable mono log; bottom glass toolbar with Copy All and Share), Read is the file excerpt
  with line numbers, Edit / Write is the full diff, Grep / Glob are matches grouped by file, WebFetch
  is the URL and the fetched text, Task is the subagent's own steps as tool rows (each opens the same
  way, so the zoom nests), MCP is the input and output as pretty JSON. Long output loads by
  `GET /v1/sessions/{id}/messages/{seq}` when the transcript copy was cut.
- **Thinking row** (v0, Grok, Granola): a tool row with the `brain` glyph. Live: "Thinking · 4s"
  with the seconds ticking (`Text(timerInterval:)`) and the newest one or two thought lines under it
  in tertiary, Grok's live view. Done: "Thought for 4s ›". Tap expands inline (a
  `DisclosureGroup`, section 6.2) to the full thinking in `.subheadline` secondary behind a 1 pt
  `separator` line; tap again folds it. Inline, not a page, because thinking is read in place next
  to the reply it led to.
- **Step group:** consecutive tool rows between two pieces of assistant text fold into one
  disclosure row: `Worked for 1m 12s · 14 steps` (mono numbers), `square.stack.3d.up` glyph. Tap
  expands inline (`DisclosureGroup`); the rows show indented 8 pt behind a 1 pt `separator` line,
  each still opening its own page. Default: folded when the turn is complete; while the turn runs
  it stays open and shows only the last three rows, with "11 more" above them. A turn with three
  steps or fewer never folds (v0 shows short runs flat). Reference: GitHub Copilot's grouped steps.
- **Diff (Edit / Write / Codex FileChange):** a card (`secondarySystemBackground`, radius 12)
  with a header row: `doc.text` glyph, file name `.subheadline.semibold`, parent path mono
  tertiary, trailing `+12 −3` (green / red, mono). Hunks: two-column gutter (old/new line numbers,
  mono `.caption2`, tertiary), lines in SF Mono 12 (`.caption` scaled), added lines on green at
  14% opacity with a 2 pt green leading bar, removed on red at 14%. Hunk headers `@@` as a quiet
  divider "Lines 120–134". Shows the first 3 hunks / 40 lines; the header and "Show full diff" both
  zoom into the full diff page (per-file sections, a Wrap toggle). Horizontal scroll per hunk, no
  wrap by default.
- **Code block:** card radius 12, `secondarySystemBackground`; header with language label
  (`.caption.monospaced()` secondary) and a Copy button (`doc.on.doc`, swaps to `checkmark` for
  1.5 s with `.success` haptic). More than 20 lines folds with "Show all 84 lines", which zooms
  into the code page (Perplexity reference): large mono text, horizontal scroll, Wrap toggle, Copy
  and Share in a glass bottom toolbar.
- **File chip** (Grok Bot): for files the session wrote or attached: a compact card
  (`secondarySystemBackground`, radius 14, hugging its content, max 80% width): a 32 pt tile with
  the file type glyph, the name in `.subheadline.weight(.medium)` with the extension in tertiary
  ("week-meal-prep`.md`"), and the size under it in `.caption.monospacedDigit()` tertiary. Tap zooms
  into the file page: Markdown rendered with the transcript's views, code in the code page,
  images in the image viewer, PDFs and everything else in `QuickLookPreview` after download.
  Context menu: Copy Path, Share, Show on Mac.
- **Images:** in a step page and in user turns: thumbnails (served 640 px JPEG), 2-up, aspect-fit
  inside radius-10 tiles with a hairline border, each a `matchedTransitionSource` for the viewer
  (section 4.12). Read results show the file name under the tile in mono.
- **Question card:** `AskUserQuestion` lives here, inline, as the last item. Section 4.6.
- **Request inline:** an open request in this session appears as the last item: a card with the
  amber leading bar, headline, the command in mono, and Allow / Deny buttons inline (Deny
  `.glass`, Allow `.glassProminent` amber). Tapping elsewhere on it opens the full approval sheet,
  which zooms out of the card. After an answer it folds to one tool-row line "Allowed · Bash npm
  test" (green check), "Denied" (secondary), or "Answered on Mac"; tapping that line unfolds the
  request again, read-only.
- **Health card:** when the session is flagged (stuck, looping, failing, or idle on a bloated
  context), a quiet card as the last item: triangle glyph, the flag's own words ("No progress for
  12 minutes"), and two buttons: Send a Message… and Restart Fresh…. It goes away when the flag
  clears. Section 4.14.
- **Turn end** (Grok): under the turn's last reply, a 32 pt row of icon buttons in tertiary: Copy
  (the reply as Markdown), Share, Fork From Here (hosted, section 4.14); trailing
  "opus · 2m 14s" in `.caption.monospaced()` tertiary. No confetti.

**Streaming and pacing** (Paseo's model, tuned):

- Deltas from the socket merge for 60 ms before reaching the store.
- The view reveals text from a buffer at an adaptive rate: `rate = max(45 chars/s,
  backlog / 0.4 s)`, revealed on word boundaries at display refresh, so the visible text never
  lags the stream by more than about 0.4 s and never jumps by a whole paragraph. New words fade
  from 0 to 1 over 120 ms (Reduce Motion: no fade, whole chunks). This fade is the one custom
  animation in the transcript; SwiftUI has no native mechanic for revealing streamed text.
- Only the last block re-parses as markdown during streaming; earlier blocks are frozen views.
  An unclosed code fence renders as a code block immediately.
- **Follow mode:** while the user is at the bottom (within 40 pt), new content keeps them there.
  Scrolling up leaves follow mode and buds a glass button off the composer (v0, Granola, Dot): a
  44 pt circle with `arrow.down`, centered above the composer; it widens into a capsule
  "↓ 3 new" when new messages arrived, and into "↓ Question" with an amber dot when a question or
  request is waiting. Tap scrolls to the bottom (`ScrollPosition.scrollTo(edge: .bottom)` in
  `withAnimation(.smooth)`) and resumes follow. Section 6.2 has the morph.
- No haptics while text streams.

**States.** Loading from cache: instant. No cache: three redacted text lines + one tool-row
placeholder. Error fetching a page: an inline row "Couldn't load earlier messages · Retry".
Session ended: the composer becomes a footer "This session ended" with **Resume** and **Fork**
(hosted, section 4.14). Non-hosted session: the composer offers Reply / Note only per section 4.4,
and the toolbar hides Terminal.

**Context menus and swipes.** Long press on assistant text: Copy, Select Text, Share. On a tool
row: Copy Command (Bash) or Copy Path, Copy Output, Open (same as tap). On a user turn: Copy, Edit
and Resend (hosted, ready only). iOS 27 adds swipe actions on transcript rows through
`swipeActionsContainer()`: leading swipe on a tool row copies its command or path. iOS 26 has the
context menu only.

**Accessibility.** Each message is an element; tool rows read "Read Island.swift, 0.4 seconds,
button, opens details". The thinking row reads "Thought for 4 seconds, collapsed". Step group:
"Worked for 1 minute 12 seconds, 14 steps, collapsed" (the `DisclosureGroup` gives the expanded
and collapsed traits for free). Diffs get a summary label ("Island.swift, 12 lines added, 3
removed") with the lines as children. Rotors: Headings, Messages from you, Tool calls, Images.

```
┌─────────────────────────────────┐
│ (‹) Fix the flaky sync test ⌨ ⋯ │ glass bar; title opens a menu
│     side-a · Work · opus        │
│                                 │
│      ( 18 earlier messages )    │
│       Yesterday at 3:06 PM      │
│           ┌─────────────────┐   │
│           │ The sync test   │   │
│           │ fails 1 in 5…   │   │
│           └─────────────────┘   │
│ ⧉ Worked for 1m 12s · 14 steps ›│
│ I found the race. The engine    │
│ resumes before the snapshot…    │
│ ┌─────────────────────────────┐ │
│ │ ▤ SyncEngine.swift  +12 −3  │ │
│ │ 118 118   let seq = …       │ │
│ │ 119     - resume()          │ │ red tint
│ │     119 + await snapshot()  │ │ green tint
│ └─────────────────────────────┘ │
│ ⌕ Searched "resume("     0.2s › │
│ ◎ Thought for 4s              › │
│ ▶ Running swift test          › │ glyph animates
│ ┃ Allow Bash?                   │ amber bar
│ ┃ swift test --filter Sync      │
│ ┃      [ Deny ]  [ Allow ]      │
│            ( ↓ 3 new )          │ glass, buds off the composer
│ (+) ╭────────────────────────╮  │
│     │ Reply…             (mic)│ │ glass composer
│     ╰────────────────────────╯  │
└─────────────────────────────────┘
```

### 4.4 Composer

References: v0 ([composer](https://mobbin.com/screens/f4489226-373f-42bf-9839-26105c144eff), [Add to Chat sheet](https://mobbin.com/screens/8b0038b7-4e24-473f-b3b6-cc84bf4956f3)), Grok Bot
([Mobbin flow](https://mobbin.com/flows/1e2f749a-8054-47cd-9049-f267dc34d362)), Dot ([Mobbin](https://mobbin.com/screens/433d9d19-7bab-4d4a-b9ea-bb51921ba4cb),
[multi-line](https://mobbin.com/screens/9a2f1269-0a21-4bcc-b0a7-b4ca5acf2315)), Granola ([scope chips](https://mobbin.com/screens/10a88684-1dfe-4ab2-8299-dacc1061a3b6)).
All four agree on the shape: a separate round `+`, a pill field, and the voice or send control
inside the pill's trailing end. Content keeps scrolling, blurred, under all of it.

**Layout.** One `GlassEffectContainer` floating 16 pt from the edges and 8 pt above the keyboard,
holding three glass shapes that blend and morph together:

1. **`+` circle**, 44 pt, `glassEffect(.regular.interactive(), in: .circle)`, leading. Opens the
   Add sheet (below).
2. **Field pill**: `glassEffect(.regular.interactive(), in: .capsule)` while one line, growing
   into `.rect(cornerRadius: 22)` as it gains lines (Dot). `TextField(axis: .vertical)`, 1–6 lines
   then scrolls, `.body`. Placeholder by mode: "Reply…" (waiting / ready), "Message…" (working,
   hosted or not), "Or type your own answer…" (a question card waits,
   section 4.6). Attachments, when present, sit inside the pill above the text: 56 pt thumbnails,
   radius 10, each with a small `xmark` remove button; upload progress as a thin ring on the
   tile.
3. **Trailing control inside the pill**, 32 pt circle, one of: `mic` (empty field, idle or
   ready: dictation), `arrow.up` on label-colored fill (text present: send; white on black in dark
   mode, the Claude iOS look, not amber), `stop.fill` in a glass circle (empty field while the
   session works: Interrupt). The symbol swaps with `.contentTransition(.symbolEffect(.replace))`;
   the circle's fill changes inside the container, so nothing jumps.

The follow-mode button (section 4.3) lives in the same container with its own `glassEffectID`, so
it buds off the composer and melts back into it.

**Send.** Sending: the button shows a progress arc until the server accepts; failure keeps the
text and shows "Not sent · Retry" under the field. Long press on the stop button (empty field)
opens a context menu (the tap stays Interrupt): Interrupt Now, Stop Before Next Step, Send a
Message…. Section 4.14.

**Long press on Send** while the session works (or starts) and there is text: a context menu of
the deliveries that session takes (`AppModel.deliveries`), from the Mac's delivery table and the
session's `abilities`. The plain tap keeps the default for each kind.

| Session | Tap | Long-press menu |
|---|---|---|
| Hosted Claude | `auto` (typed; Claude reads it at its next step) | Send at Next Step, Send After This Turn (`followUp`, when listed), Interrupt and Send |
| Hosted Codex | `auto` (typed; steers the turn) | Steer Now, Send After This Turn (`followUp`), Interrupt and Send. A Mac before 0.5.52 lists no `followUp` and refuses a reply mid-turn: Interrupt and Send only |
| Codex with `replyTerminal` | steer | Steer Now, Send After This Turn (`submit: queue`), Interrupt and Send |
| Claude outside Side A's terminals | `auto` (a note, read at its next step) | Send at Next Step, Send After This Turn (`followUp`: the Stop waiter's queue, when listed) |
| Codex outside, mail hooks on | `auto` | Send at Next Step (`note`) |

Unhosted Claude has no instant interrupt (only stop mail, which waits for the next step and
shares the one mail slot), so it offers no Interrupt and Send. **Interrupt and Send** sends the
interrupt first and queues the reply only once the Mac has taken it, so the two never arrive out
of order; for Codex it also waits (up to 8 s) for the session to stop working, since a turn
still running refuses or steers the text. A refused interrupt sends nothing: the text goes back
into the field with "Couldn't stop it. …" under it.

While the Mac is offline, Send is off and dimmed and the one status line under the field gives
the reason. Back in front after the link dropped in the background, an unreachable Mac reads as
Reconnecting… for its minute again (`MacConnection.foregrounded`), so Send stays usable while
the link comes back; the outbox holds what's sent meanwhile.

**Dictation.** `mic` records with the iOS 26 Speech framework's on-device `SpeechTranscriber`
and writes into the field as it hears; tap again (or Send) ends it. The mic is hidden when speech
permission is denied; the keyboard's own dictation key still works.

**Modes.** The composer sends `mode: auto` and protocol's [delivery table](protocol.md#delivery-table)
decides; the placeholder reads from the same table so it never promises something else: Ready →
follow-up (carrying the finished turn's `turnID`). Working and hosted → typed into the TUI now
(Claude) or refused (Codex). Working and not hosted → a note for Claude (reaches the session at
its next step and can be taken back until then: it shows as an ordinary outgoing bubble with
"Next step" and a `clock` under it, Edit and Delete in its menu, and once read it looks like any
delivered message), refused for Codex. While the Mac is offline, a bubble not yet confirmed
(sending, next step, after this turn) reads "Not confirmed" with the offline reason's glyph. Status `unknown` → the composer is disabled
with "MacBook Pro can't tell what this session is doing." Waiting on a question → the text
becomes that question's "write your own" answer (`answers` with `other`) and posts through
`POST /v1/requests/{rid}/answer`; a plain reply would get 409 `session_waiting`.

**Add sheet** (v0's Add to Chat). `+` opens a `.sheet` that zooms out of the `+` circle, with
`presentationDetents([.medium, .large])` and the system glass at the medium detent. Its own
`NavigationStack`:

- Top row, three equal tiles (icon over label): **Camera**, **Photos** (`PhotosPicker`, up to 5),
  **Files** (`fileImporter`). A fourth, **Paste**, appears when the pasteboard holds an image.
- Then an inset grouped list: **Model** (trailing "opus ›"), **Effort** ("high ›"), each a push
  inside the sheet to a checkmark list of the options `GET /v1/options` lists for that agent
  (`AgentOptions.models`, `.efforts`); **Commands ›** (`AgentOptions.commands`, the slash command
  list including custom ones); **Send as** (Note / Send now, for working hosted sessions only).
- Choosing a model or effort sends the slash command as a `keys`-mode reply for hosted sessions
  and closes the sheet. For non-hosted sessions Model and Effort show as read-only rows
  ("Change on your Mac") because the phone can't type into that terminal.

Images are downscaled to 2048 px long edge, HEIC → JPEG, MIME sniffed (Happy), uploaded via
`POST /v1/uploads`; the returned `Upload.id` goes into the reply's `attachments` (the Mac turns ids
into paths). The model and effort in use are always
visible in the navigation subtitle, so the composer itself needs no chip row.

**Slash commands.** Typing `/` at the start opens a suggestion panel above the field (glass, in
the composer's container so it materializes out of it, max 5 rows): `/model`, `/effort`,
`/compact`, `/clear`, `/review` and the custom commands `GET /v1/options` lists. Each
row: command in mono, one-line description secondary. Deleting the `/`, tapping outside, or Esc
closes it. Arrow keys and Return work with a hardware keyboard.

**Hardware keyboard.** Return sends, Shift-Return newline, Cmd-. interrupts, Esc dismisses the
keyboard. `keyboardShortcut`s are listed in the iPad shortcut overlay.

**Limit banner.** When the session's account is over 90% on a window, a single line above the
composer (Claude iOS reference): "Work is at 94% of its 5-hour limit · resets 3:40 PM", mono
numbers, dismissible per session.

**Haptics.** `.impact(.light)` on send accepted. None on typing.

**Accessibility.** "Add, button, attachments, model and commands". The trailing control reads
"Dictate", "Send" or "Interrupt session" by state; the Add sheet rows read "Model, Opus, double tap
to change".

### 4.5 Approval sheet

**Presentation.** `.sheet` with `presentationDetents([.medium, .large])`, glass background at the
medium detent (system), `presentationDragIndicator(.visible)`. Opens from a row, the bottom
accessory, a notification, or the inline card. When several requests wait, the sheet pages
between them (see the pager below).

**Layout, top to bottom:**

- Context line: agent glyph + "Claude · side-a · Work" in `.footnote` secondary, trailing
  "1 of 3" with chevrons when several wait.
- Headline: "Allow Bash?" / "Allow edit to Island.swift?" / "Allow WebFetch?" in
  `.title3.weight(.semibold)`.
- Risk label (destructive only): red capsule with `exclamationmark.triangle.fill` + the reason
  ("Deletes files", "Edits Claude Code settings").
- Payload: command in a mono block (`secondarySystemBackground`, radius 12, selectable, wraps,
  max 8 lines then scrolls), or a compact diff (section 4.3 diff card), or URL + method for fetch.
  The session's last assistant sentence above it in secondary text, when it explains the request.
- Buttons, bottom-pinned, full width, 50 pt:
  - Gate `.lockScreen` or `.unlock` (protocol, `AllowGate`; the app is already unlocked):
    **Allow** (`.glassProminent`, amber), **Deny** (`.glass`), and "Always allow `Bash(npm test:*)`"
    as a text button below with the exact rule in mono.
  - Gate `.biometric`: **Deny** (`.glass`) and **Allow…** (`.glass` with red text). Allow requires Face
    ID / passcode (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`), then sends
    `confirmDestructive: true`, and never offers Always. No button is the default; nothing is
    bound to Return.
  - The risk label and colour come from `risk`, which is presentation only; which buttons appear
    and what they need comes from `gate`.
- Answered elsewhere: the sheet content cross-fades to "Answered on Mac" with a check and closes
  after 1 s.

**Haptics.** `.warning` when the sheet opens because a request arrived in the foreground;
`.success` on Allow; `.impact(.rigid)` on Deny; `.error` if the post fails.

**Accessibility.** VoiceOver focus lands on the headline; the command is read character-aware
(`.speechSpellsOutCharacters` off, but `accessibilityTextContentType(.sourceCode)`). Magic Tap
does nothing here on purpose (no gesture approves).

```
┌─────────────────────────────────┐
│               ───               │
│ * Claude · side-a · Work  ‹1/3› │
│ Allow Bash?                     │
│ ⚠ Deletes files                 │ (destructive only, red)
│ ┌─────────────────────────────┐ │
│ │ rm -rf .build && swift build│ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │
│ │           Allow             │ │ amber, glassProminent
│ └─────────────────────────────┘ │
│ ┌─────────────────────────────┐ │
│ │            Deny             │ │ glass
│ └─────────────────────────────┘ │
│   Always allow Bash(swift build:*)
└─────────────────────────────────┘
```

### 4.6 Question card

Claude's `AskUserQuestion` (one to four questions, each with two to four options and an implied
"write your own").

**Where it lives: inline in the transcript, not in place of the composer.** Two shapes were on
the table: the inline card of Grok Bot
([Mobbin flow](https://mobbin.com/flows/1e2f749a-8054-47cd-9049-f267dc34d362)), and
Claude iOS, where the options replace the composer. Recommendation: **the inline card**, because

- the question stays next to the text that asked it and scrolls with it; a panel over the
  composer floats above whatever happens to be on screen and hides the last lines of the reply
  that explain the question;
- it is the same shape as the inline request card (section 4.3), so everything the agent waits
  on looks and folds the same way, and once answered it stays in the history as a readable line
  instead of vanishing with the panel;
- the composer stays where it is and keeps working: typed text becomes the "write your own"
  answer, so there's one text field on screen, not two;
- four options with descriptions are taller than a phone's composer area with the keyboard up;
  in a scrolling card they never need a nested scroll view.

The cost: the card can be off screen. That's covered by the follow-mode button turning into
"↓ Question" (amber dot) and by every entry point (Sessions row, bottom accessory, notification,
Live Activity) opening the session scrolled to the card with `ScrollPosition.scrollTo(id:)`.
The old question sheet is dropped. The Notification Content Extension keeps its own compact
pager (section 5.3), since there's no transcript there.

**Layout** (Grok Bot):

- A card, `secondarySystemBackground`, radius 20, padding 16, full width minus 16 pt margins.
- Header line: the question's short `header` in `.caption` secondary (uppercase off), trailing
  "1 of 2" in `.caption.monospacedDigit()` tertiary when there are several.
- Question text in `.headline`.
- Options as an inset grouped list inside the card (`systemBackground`, radius 14, hairline
  separators inset past the badge): leading letter badge **A–D** (`.subheadline.monospaced()`
  tertiary, in a 24 pt `tertiarySystemFill` rounded square, radius 6), label in `.body`,
  description under it in `.subheadline` secondary. Row min height 48. Options marked
  "(Recommended)" show that word as a `.caption` secondary suffix, not in the label.
- Last row: `pencil` badge and "Write your own…". Tapping it focuses the composer (its
  placeholder already says "Or type your own answer…"); the card doesn't grow a second field.
- Single select: the picked row shows a `checkmark` trailing (`.symbolEffect(.replace)`) with
  `.selection` haptic; after 250 ms the card moves to the next question. Multi select: checkmarks
  toggle, and a **Next** button (`.glass`) appears under the list.
- Paging inside the card: the outgoing question leaves and the next arrives with the system
  `.push(from: .trailing)` transition in `withAnimation(.smooth)` (Reduce Motion: `.opacity`). An
  answered question folds into a summary line above the current one ("Storage · Caches
  directory", `.subheadline` secondary, `checkmark` glyph); tapping it goes back to that question
  with `.push(from: .leading)`, answers kept. The Mac island keeps answers in progress too, so
  they mirror if the server shares them (protocol open question 3).
- After the last question: the summary lines plus **Send Answers** (`.glassProminent` amber,
  full width inside the card). Answers post together. A single single-select question skips the
  summary and sends on the pick, after the same 250 ms.
- Answered: the card folds into one tool-row line, "Answered · Caches directory" with a green
  check, or "Answered on Mac"; tapping it unfolds the questions and the picks, read-only
  (`DisclosureGroup`).
- Hardware keyboard: A–D or 1–4 pick, Return advances.

```
│ I can put the cache in two places.│
│ ┌─────────────────────────────┐ │
│ │ Storage                1 of 2│ │
│ │ Where should the cache live? │ │
│ │ ┌─────────────────────────┐ │ │
│ │ │ [A] App Group            │ │ │
│ │ │     Shared with widgets  │ │ │
│ │ ├─────────────────────────┤ │ │
│ │ │ [B] Caches directory   ✓ │ │ │
│ │ │     Purgeable by the OS  │ │ │
│ │ ├─────────────────────────┤ │ │
│ │ │ [✎] Write your own…      │ │ │
│ │ └─────────────────────────┘ │ │
│ └─────────────────────────────┘ │
│ (+) ╭────────────────────────╮  │
│     │ Or type your own answer…│  │
│     ╰────────────────────────╯  │
```

### 4.7 Plan approval

`ExitPlanMode`. Full sheet (large detent by default) because plans are long.

- Title "Review plan", context line as in the approval sheet.
- The plan rendered with the transcript's markdown views on `systemBackground`, scrollable.
- Bottom, in a glass bar (`safeAreaBar`): **Approve** (`.glassProminent` amber) with a menu
  chevron segment offering "Approve and accept edits"; **Keep planning** (`.glass`) which opens a
  text field for feedback (sent as the deny reason).
- Approve and accept edits states plainly what it does in one line under the button: "Edits
  won't ask again in this session."
- Haptics: `.success` on approve, `.impact(.rigid)` on keep planning.

```
┌─────────────────────────────────┐
│ Cancel      Review plan         │
│ * side-a · Work                 │
│                                 │
│ ## Plan                         │
│ 1. Move wire types to           │
│    SideAProtocol                │
│ 2. Add RemoteServer…            │
│ …                               │
│╭───────────────────────────────╮│
││ [Keep planning] [Approve | ▾] ││ glass bar
│╰───────────────────────────────╯│
└─────────────────────────────────┘
```

### 4.8 New session

Reference: Linear's new issue sheet. A large sheet (`.large` detent, no drag-to-dismiss while
the prompt has text: `interactiveDismissDisabled` with a "Discard?" confirmation).

- Top bar: Cancel (leading), title "New Session", **Start** (trailing, `.glassProminent` amber
  only when a project and prompt exist).
- Prompt field fills the sheet: `TextEditor` at `.body`, placeholder "What should it do?",
  autofocused.
- **Chip bar above the keyboard** (`.toolbar { ToolbarItemGroup(placement: .keyboard) }` or a
  `safeAreaInset` bar that rides the keyboard), horizontally scrolling glass chips:
  `Mac` (only with 2+), `Project` (folder glyph + name), `Agent` (Claude / Codex glyph), `Model`,
  `Worktree` (off / new `sidea/<name>`), `Account` (Auto, or a specific account with its
  tightest limit in mono). Each chip opens a `Menu`, except Project which opens a searchable list.
- **Project picker:** searchable list (`.searchable`), sections "Recent" (last 5 projects
  used) and "All projects", each row: folder name `.body`, path mono `.caption` tertiary, branch
  in a mono capsule. Git roots show `arrow.triangle.branch`.
- Before the user types, recent projects show as suggestion rows under the prompt (Linear's
  suggestions), one tap sets the Project chip.
- Attach photos with the same `+` as the composer.
- Start: posts `/hosted` with a client-generated id (idempotent), the sheet closes, the app pushes
  to the new session with a placeholder "Starting…" transcript that fills when the session
  appears. `.success` haptic.
- Errors inline above the chips: "Codex isn't installed on MacBook Pro", "That folder isn't a git
  repository, so a worktree isn't available".

```
┌─────────────────────────────────┐
│ Cancel     New Session    Start │
│                                 │
│ What should it do?│             │
│                                 │
│ RECENT                          │
│ ▢ side-a      ~/Coding/side-a   │
│ ▢ smogcrm     ~/Coding/smogcrm  │
│                                 │
│─────────────────────────────────│
│ (▢ side-a)(* Claude)(opus)(⑂ Off)(Auto) │ chips over keyboard
│ ┌─────────────────────────────┐ │
│ │  q  w  e  r  t  y  u  i  o  │ │
└─────────────────────────────────┘
```

### 4.9 Terminal

For hosted sessions (M3). Reference: Blink and Prompt.

- Full bleed, always dark (`#0F1312` background regardless of system appearance), status bar
  hidden (`toolbarVisibility(.hidden, for: .statusBar)` on 27, `statusBarHidden` on 26),
  navigation bar hidden. SwiftTerm `TerminalView` in a `UIViewRepresentable`, SF Mono 13 by
  default (Settings: 10–18), pinch to change size live, with a centered glass HUD "13 pt · 54×38"
  for a second.
- **Back to chat** glass capsule top-left (`chevron.left` + "Chat"), session name in a small mono
  glass capsule top-center, fades out after 3 s of typing and back on tap near the top edge.
- **Key bar** riding the keyboard (`inputAccessoryView` on the terminal view, hosted SwiftUI):
  glass capsules in a `GlassEffectContainer`: `esc`, `ctrl` (sticky toggle; lit state
  is label-colored fill), `tab`, `↑ ↓ ← →` (with a trackpad mode: long-press the arrow cluster and
  drag to move the cursor), `⌃C`, `/`, `|`, `~`, and a keyboard-hide button. Horizontal scroll if
  narrow. Keys repeat on hold. `.selection` haptic per key tap (respects system "Keyboard
  Feedback" setting by using `UIDevice.current.playInputClick()` instead where it applies).
- Predictive echo (Codeman port): guessed glyphs on the prompt row render at 60% opacity until
  confirmed.
- Copy: long press enters selection (SwiftTerm), with a Copy / Paste / Select all edit menu.
  Paste goes in as a bracketed paste.
- Scrollback: two-finger swipe or the scroll indicator scrubs tmux history.
- Window size: when the Mac has typed in the last minute, a top banner "Sized for MacBook Pro"
  explains a letterboxed grid.
- States: connecting (the last screen frame from cache dimmed, plus "Attaching…"), disconnected
  (banner "Reconnecting…", input buffered and replayed via acked input), session ended ("Process
  exited" with **Back to chat**).
- Accessibility: SwiftTerm's accessibility (the screen as text lines), key bar buttons labeled
  ("Escape", "Control, toggle"). Reduce Motion: HUDs appear without scaling.

```
┌─────────────────────────────────┐
│(‹ Chat)   ( sa-side-a-3f2c )    │
│ ╭─────────────────────────────╮ │
│ │ ✻ Welcome to Claude Code    │ │
│ ╰─────────────────────────────╯ │
│ > fix the flaky test▌           │
│                                 │
│ ? for shortcuts                 │
│                                 │
│                                 │
│ (esc)(ctrl)(tab)(↑)(↓)(←)(→)(⌃C)(⌄) │ glass key bar
│ ┌─────────────────────────────┐ │
│ │  q  w  e  r  t  y  u  i  o  │ │
└─────────────────────────────────┘
```

### 4.10 Accounts

**Layout.** Large title "Accounts". Top: the **LCD readout**, the one Side A identity moment in
the app: a 72 pt-tall plate (radius 14) in the LCD tokens (section 7.1) with inner shadow, SF Mono
`.title3` semibold, uppercase:

```
WORK      5H  82%   RESETS 2:14
```

It names the account in use and its tightest limit. Tap scrolls to that account.

Below, a 2-column `LazyVGrid` of account cards (1 column at accessibility sizes), grouped by
provider (Claude, Codex) with plain section headers:

- **Card:** `secondarySystemGroupedBackground`, radius 22, padding 16. Rings (88 pt): outer ring
  weekly, inner ring 5-hour (Fitness rings; inside the inner ring, the tighter percent in mono
  `.headline.monospacedDigit()`). Under the rings: account name `.headline`, "In use" capsule when
  active, and two mono lines: `5h  82% · 2:14` and `wk  41% · Thu`.
- **Ring colours:** track at `quaternarySystemFill`; fill label color at 85% for 0–74%, amber for
  75–96%, red at 97%+ (Side A's "limited"). A Fable / Opus weekly cap, when reported, adds a third
  thin ring outside.
- **Stale:** a reading older than 15 minutes shows "as of 1:02 PM" under the lines, and the
  rings draw at 60% opacity (the numbers stay full contrast). Never a guessed percent.
- Ring fill animates from 0 on first appearance (spring damping 1.0, response 0.8) and between
  values with `.contentTransition(.numericText())` on the numbers. Reduce Motion: no sweep.

**Account detail** (push): big rings (180 pt), then an inset grouped list: 5-hour (percent,
resets at, "resets in 2h 14m" with `Text(timerInterval:)`), weekly, model caps, Autopilot
(included or not, read-only: "Change on your Mac"), "Sessions on this account" (rows like the
Sessions list). No editing of accounts from the phone in v1.

**States.** Empty: "No accounts yet. Add one in Side A on your Mac." Loading: rings as tracks only.

**Accessibility.** Card label: "Work, in use. 5-hour limit 82 percent, resets at 2:14 PM. Weekly
41 percent, resets Thursday." Rings are decorative to VoiceOver.

```
┌─────────────────────────────────┐
│ Accounts                        │
│ ┌─────────────────────────────┐ │
│ │ WORK   5H 82%   RESETS 2:14 │ │ LCD plate
│ └─────────────────────────────┘ │
│ CLAUDE                          │
│ ┌──────────────┐┌─────────────┐ │
│ │   ◯◯ 82%     ││   ◯◯ 12%    │ │
│ │ Work [In use]││ Personal    │ │
│ │ 5h 82% · 2:14││ 5h 12% · 4:50│ │
│ │ wk 41% · Thu ││ wk  8% · Mon│ │
│ └──────────────┘└─────────────┘ │
│ CODEX                           │
│ ┌──────────────┐                │
│ │   ◯◯ 30%     │                │
│ │ Team         │                │
│ └──────────────┘                │
│ ╭───────────────────────╮ ╭──╮  │
│ │ Sessions   Accounts   │ │⌕ │  │
│ ╰───────────────────────╯ ╰──╯  │
└─────────────────────────────────┘
```

### 4.11 Search

The search tab (`Tab(role: .search)`) is also History (section 4.14): the field sits in the glass
bar at the bottom. Before typing: "Recent searches", then History's Pinned and Recent lists. Results come from Side A's search index on the
Mac (what was asked, the replies, the commands that ran), grouped by session: session title,
project · account · date in mono, and the matching snippet with the match in bold. Tap opens the
transcript scrolled to the match with the match briefly highlighted (a
`tertiarySystemFill` flash). Uses `GET /v1/search` (protocol, M3). Offline:
"Search needs a connection to MacBook Pro."

### 4.12 Image viewer

References: v0's image in a user turn ([Mobbin](https://mobbin.com/screens/9ec98b14-9357-4da9-949e-52dbb1d54caf)) and Dot's
([Mobbin](https://mobbin.com/screens/d603ac4a-63af-4177-83b3-4818292d0302)) for the thumbnail; Photos for the viewer itself.

- **Open:** tap a thumbnail. The tile is a `matchedTransitionSource(id: imageID, in: ns)` and the
  viewer a pushed page with `.navigationTransition(.zoom(sourceID: imageID, in: ns))`, so the
  image grows out of its tile. Thumbnail shown first, full resolution swapped in after the
  transition (no blank frame).
- **Close:** drag down anywhere (the zoom transition's own interactive dismissal: the image
  follows the finger, shrinks, and flies back into its tile on release; letting go early springs
  it back open), edge swipe, or the glass back button. No custom gesture code. Reduce Motion: the
  system turns the zoom into a cross-fade.
- Black background, image aspect-fit, pinch to zoom (to 4x), double tap toggles 1x / 2.5x at the
  tap point, pan when zoomed. SwiftUI has no zooming scroll view, so this one piece is a
  `UIScrollView` in a `UIViewRepresentable` (its native zoom, bounce and deceleration), not a
  hand-built gesture stack. While zoomed in, drag-down pans instead of closing.
- Swipe horizontally pages through the session's images: a paged `ScrollView`
  (`.scrollTargetBehavior(.paging)`). The zoom source follows the current page, so closing on
  image 5 flies back into tile 5.
- Chrome (tap to toggle, `.toolbarVisibility` with `.smooth`): glass back button top-left,
  "3 of 7" top-center mono; bottom glass toolbar: **Copy** (`doc.on.doc`, image to pasteboard,
  `.success` haptic, a "Copied" HUD), **Save** (`square.and.arrow.down`, add-only Photos access,
  "Saved to Photos"), **Share** (`ShareLink` with a `Transferable` image and the file name).
  Caption line above the toolbar: tool and file ("Read · screenshot.png · 1.2 MB").
- Accessibility: image label from the tool context ("Screenshot from Read, screenshot.png");
  zoom via the VoiceOver magnify gesture; actions as `accessibilityActions`.

### 4.13 Settings

The Settings tab, between Accounts and Search. Inset grouped `Form`.

- **Macs:** each paired Mac: name, status dot, "Side A 0.6.1 · Connected via Relay" (Wi‑Fi, Tailscale or
  Relay: the path `Paths` chose, a LAN address being Wi‑Fi), or how long ago it was seen. Detail: **Name** (pushes a field,
  as Settings › General › About › Name does; a nickname kept per Mac in the App Group's defaults,
  `MacNicknames`, that wins over the Mac's own name everywhere the phone shows it and survives its
  hellos; cleared, it's the Mac's name again; Forget clears it), Connection, Tailscale address (copyable mono), **Remove this iPhone** (destructive, confirmation;
  revokes the token on the Mac when reachable). **Pair Another Mac** opens the scanner.
- **Macs** detail also has **Test Connection** (setup, Diagnostics), and that Mac's own
  Notifications and Live Activity switches:
  - **Notifications:** Requests, Questions, Plans, Finished, Limit warnings, Stuck sessions,
    Autopilot moves, "Time Sensitive for requests", "Quiet while I'm watching the session".
    These are `NotificationPrefs`, sent in `PushRegistration.prefs` with every push registration
    to that Mac, so it doesn't send what's off. Stored as `<key>.<macID>`; a Mac never set reads
    the switch from before there was one per Mac.
  - **Live Activity:** on/off (`prefs.liveActivity`); off ends that Mac's running activity.
- **Security:** a fixed explanation, not toggles: "From the Lock Screen you can allow reading and
  searching, and edits inside the project. Commands, MCP tools and anything that widens
  permissions need the iPhone unlocked. Destructive requests need Face ID in the app." The Mac
  decides each request's gate; the phone can't loosen it.
- **Terminal:** font size stepper with live preview.
- **About:** version, "What's new", Privacy (the app collects nothing; session traffic stays
  between the iPhone and the Mac; the push relay sees only device tokens and ciphertext),
  **Acknowledgements** (SwiftTerm MIT, Codeman MIT, Paseo Apache-2.0 with changed-file notice,
  Happy MIT; full licence text in a pushed mono view), Support link.

Toggles use system green explicitly (`.tint(.green)`) so amber stays meaning "needs you".

```
┌─────────────────────────────────┐
│ ‹  Settings                     │
│ MACS                            │
│ ┌─────────────────────────────┐ │
│ │ ● MacBook Pro        now  › │ │
│ │ ＋ Pair Another Mac          │ │
│ └─────────────────────────────┘ │
│ NOTIFICATIONS                   │
│ ┌─────────────────────────────┐ │
│ │ Requests               (●)  │ │
│ │ Questions              (●)  │ │
│ │ Plans                  (●)  │ │
│ │ Finished               (●)  │ │
│ │ Limit warnings         (●)  │ │
│ └─────────────────────────────┘ │
│ LIVE ACTIVITY · SECURITY ·      │
│ TERMINAL · ABOUT                │
└─────────────────────────────────┘
```

### 4.14 Only in Side A

What [the plan's "Only in Side A"](../remote.md#only-in-side-a) lists, and where each one lives on
the phone. None of it hides behind a settings screen: each action sits on the object it acts on,
reachable three native ways (swipe on the row, the row's context menu, the session's toolbar
menu), and the state it reports shows on the row itself.

**History.** The Search tab is History (`Tab(role: .search)`, section 4.11).

- Before typing: **Pinned**, then **Recent** grouped by project (quiet project subheaders as in
  section 4.2), then a **Show archived** row at the bottom. A conversation forked from another sits
  under it, indented 16 pt with an `arrow.turn.down.right` glyph (an `OutlineGroup` over the
  parent links; a fork's own forks nest further). Row: title, `project · branch · date` in mono,
  agent glyph.
- Typing searches asks, replies and commands (`GET /v1/search`) and groups results by session as
  section 4.11 describes.
- **Swipe** leading: Pin / Unpin. Trailing: Archive (Unarchive under Show archived).
- **Context menu** (preview: the conversation's last reply): Resume, Fork, Pin, Rename…, Archive,
  Copy Conversation ID.
- Tapping a past session opens its transcript read-only, the same view as section 4.3. In place
  of the composer, a glass bar with **Resume** (`.glassProminent`) and **Fork** (`.glass`). Each
  is a `Menu(primaryAction:)`: tap starts it hosted right away on the account Autopilot would
  pick, in the same folder; long press offers On Account ›, In a New Worktree, and Model ›. It
  calls `POST /v1/hosted` with `resume` (and `fork: true`), then replaces the route with the new
  live session.
- Pin, rename and archive stay in Side A, as on the Mac; nothing touches Claude's or Codex's
  files. The title menu of a live session (section 4.3) offers Rename and Pin too.

**Health.** The Mac's flags (`RemoteSession.flag`): stuck (no progress for 10 minutes), loop (the
same step 3 times among the last 6), failing (4 failed steps in a row), bloated (idle on 150k+
tokens of context).

- On the Sessions row: line 3 shows the flag's words with a triangle glyph, replacing the step;
  only failing is red. Bloated reads "Idle · 162k context".
- In the session: the health card as the last transcript item (section 4.3) with Send a Message…
  and Restart Fresh…, and the flag at the top of Session Info.
- Push: one notification when a flag starts (category `HEALTH`, passive interruption level,
  actions Restart Fresh… and Open), at most once per session per hour.

**Restart Fresh.** For a stuck, looping or heavily compacted session. Offered on the health
card, in the toolbar's Session section, in the row's context menu, and on bloated idle rows.

- Opens a `.large` sheet titled "Restart fresh" with the handoff the Mac drafts (goal, branch,
  what failed, next steps, last messages), each part an editable section in an inset grouped
  `Form` (`TextField(axis: .vertical)`, mono for branch and commands). A **Preview** toggle in the
  sheet's toolbar renders the whole handoff with the transcript's markdown views, exactly as the
  new session will receive it.
- Below the sections: Account (defaults to the session's, or Autopilot's pick), Model, and a
  "Same folder · side-a" line (read-only).
- Toolbar: Cancel (leading), **Restart** (`.confirmationAction`, `.glassProminent` amber).
  Restart ends the old session, starts a hosted one in the same folder with the edited handoff as
  its first prompt, and replaces the route with the new session. Once anything is edited, swiping
  down asks "Discard changes?" first.
- If the old session is working, Restart first asks in a `confirmationDialog`: "It's still
  working. Stop it and restart?".

**Steer without typing.** Send a Message…, Stop Before Next Step, Take Back; every session, hosted
or not, gated by `abilities`. The phone never shows the mail metaphor: a note on the wire is a
message waiting for the next step on screen.

- **Swipe** on a working row: leading **Message** (opens the message sheet), trailing **Stop**
  (Stop Before Next Step; full swipe off). While a message or stop waits (`mail`), the trailing
  action becomes **Take Back** and line 3 reads "Message waiting" or "Stops after this step" in
  secondary text with a `clock` or `pause.circle` glyph.
- **Context menu** on the row and the session's toolbar `⋯` Steer section: Send a Message…, Stop
  Before Next Step, Interrupt Now (hosted only: Esc right away), Take Back.
- In the session, the composer's stop button has the same three as its long-press menu, and Send
  has its own delivery menu (section 4.4). A message typed while an unhosted Claude works waits
  for its next step (section 4.4 modes); a tap on it offers Edit, Copy and Delete. A waiting
  message this phone didn't send shows as a quiet "Message waiting" line with Delete Message.
- The message sheet: `presentationDetents([.height(240), .medium])`, a focused multi-line field,
  **Send** in the toolbar.

**Ports and servers.**

- On the Sessions row: line 3 adds, trailing, the listening ports and memory in mono tertiary
  (`:3000 :5173 · 1.4 GB`; memory only from 1 GB, as on the Mac).
- **Context menu** on the row, Ports section in the session's `⋯` menu, and Session Info, per
  port: **Preview :3000**, **Stop Server on :3000…** (confirmation: "The session keeps running").
  And **Quit Session…** (confirmation: "You can resume it later").
- **Preview** (`POST …/ports/{port}/preview` → `{url}`) opens a `.large` sheet with a SwiftUI
  `WebView` (iOS 26 WebKit for SwiftUI) on that URL, which Side A serves through its own pinned
  listener; the WebView's navigation delegate pins the Mac's key like every other connection.
  Glass bottom toolbar: Back, Forward, Reload, the port in mono, Share URL (no Open in Safari:
  Safari can't pin). Swipe down closes it when the page is at its top; Done always does; closing
  sends `DELETE` so the preview goes down.
- **Quit Idle…**: on the folded "6 idle sessions" row, as its trailing swipe and in its context
  menu, when any have sat idle 30 minutes or more. Confirmation names the count and says each can
  be resumed. Also in the Mac sheet below.
- **Memory pressure**: when the Mac reports it and sessions hold 4 GB or more, a banner row at the
  top of Sessions: "Memory is tight on MacBook Pro · sessions hold 9.2 GB", tap opens the Mac
  sheet.

**Accounts and Autopilot** (the Accounts tab, section 4.10).

- Under the account cards, an **Autopilot** section: on or off (read-only, "Change on your
  Mac"), then its recent decisions as rows, newest first: "Moved 2 sessions Work → Personal",
  the reason under it in secondary ("Work reached 95% of its 5-hour limit"), time trailing in mono.
  Waiting and failed decisions show too ("Waiting for a pause", "No account has room"). Tap
  expands a row inline (`DisclosureGroup`) to the sessions it moved.
- **Move Now**: in the Accounts toolbar `⋯` menu and on the Autopilot section header, when
  Autopilot has a move it is holding (for example waiting for a pause); a `confirmationDialog`
  says which sessions move where and that they lose their prompt cache.
- **Worth at API prices**: one line in each account detail ("Worth $412 at API prices · 30 days",
  mono numbers) and a 7 / 30-day pair at the bottom of the Accounts tab.
- **Claude incidents**: while Anthropic's status page reports one, a banner row at the top of
  Sessions and Accounts ("Claude incident: elevated errors on Opus"), tap opens the status page in
  `SFSafariViewController`.
- Session rows and Session Info already name each session's account.

**The Mac itself.** The Mac chip (section 4.2) opens the Mac sheet (`[.medium, .large]`):

- Status (connected and how: Wi‑Fi, Tailscale or Relay; last seen), **On power** or "On battery · 64%", memory in use and pressure.
- **Keep Awake While Agents Work** toggle (system green), mirroring the Mac's setting.
- **Quit Idle Sessions…** (when any qualify).
- **Clean Up…** pushes the Mac's Clean Up inside the sheet: what conversations take on disk,
  **Archive Older Than** (a `Picker`: 30 / 60 / 90 days; pinned and running stay) with a
  confirmation, **Restore Archived**, and the left-behind worktrees as rows (path in mono, branch,
  size) with trailing swipe **Remove…**. The Mac's rules hold: removal never forces, and it keeps
  worktrees with changes, in use, on no branch, or holding ignored files like `.env`; a kept one
  says why instead of offering Remove.

**Sessions row, all together** (replacing the swipe and context-menu lines of section 4.2):

| Row state | Leading swipe | Trailing swipe | Context menu (in groups) |
|---|---|---|---|
| Needs you | Allow (non-destructive only, full swipe off) | Open Terminal (hosted) | Open, Answer…, Open Terminal |
| Working | Message | Stop (Take Back while a message waits) | Send a Message…, Stop Before Next Step, Interrupt Now, Take Back · Preview :port, Stop Server…, Quit Session… · Restart Fresh… · Open Terminal, Copy Session ID |
| Ready | Reply | Quit | Reply, Fork · Restart Fresh… · Quit Session… |
| Idle | Continue on iPhone | Quit | Continue on iPhone, Restart Fresh…, Quit Session…, Pin, Rename… |
| Idle fold row | none | Quit Idle | Quit Idle… |

Every context menu has the last assistant message as its preview.

### 4.15 Endpoints

Every feature above has its contract, capability and milestone in protocol's
[Only in Side A endpoints](protocol.md#only-in-side-a-endpoints), which replaced the table that
stood here. Each shows only when the Mac lists its capability, else "Update Side A on your Mac
to …".

---

## 5. Notifications, Live Activity, widgets, controls, intents

### 5.1 Categories and actions

Wire categories and their payloads are protocol's [Push payloads](protocol.md#push-payloads). The
phone registers these local categories; the Lock Screen gate decides which actions run without
unlocking (protocol, `AllowGate`). Risk heuristics only label; they never make an action
easier.

| Category | Actions | Interruption | Notes |
|---|---|---|---|
| `REQUEST_SAFE` (local only) | Allow (no authentication), Deny (`.destructive` style), Open | `.timeSensitive` | Set by the Service Extension only for a `REQUEST` whose decrypted payload says `gate: lockScreen`: reads and searches, edits inside the project. |
| `REQUEST` | Allow (`.authenticationRequired`), Deny, Open | `.timeSensitive` | Gate `.unlock`: any shell command, MCP or unknown tool, fetch. Allow asks for Face ID / passcode before it runs. Also what a request shows when decryption fails, but then Allow has no request id and opens the app instead. |
| `REQUEST_DESTRUCTIVE` | Deny, Open | `.timeSensitive` | Gate `.biometric`. Allow only in the app behind Face ID. Body says "Destructive · Open to review". |
| `QUESTION` | Open | `.timeSensitive` | Content Extension shows the options as tappable rows when the payload is `full`; otherwise only Open ("Claude has a question · Open to answer"). |
| `PLAN` | Approve (`.authenticationRequired`), Approve + accept edits (`.authenticationRequired`), Open | `.active` | Content Extension renders the plan's first screen when `full`. Approving starts work and accept edits widens permissions, so both need unlock. |
| `FINISHED` | Reply (`UNTextInputNotificationAction`, `.authenticationRequired`, placeholder "Follow up…"), Open | `.active` | A follow-up is a new prompt, so it needs unlock. Carries the payload's `turnID`. |
| `LIMIT` | Open | `.passive` | "Work reached 95% of its 5-hour limit · resets 3:40 PM". |
| `HEALTH` | Restart Fresh… (opens the app on the handoff sheet), Open | `.passive` | "side-a: no progress for 10 minutes". Once per session per hour (section 4.14). |
| `TEST` | none | `.active` | Test Connection's notification (setup). |
| `ANSWERED` | none | `.passive` | The relay's dismiss: "Answered on Mac" replaces the request with the same collapse id. |

- Title: the payload's `title` ("Allow Bash"); subtitle: `side-a · Work` (plus Mac name with 2+
  Macs); body: the command or question, truncated by the system.
- `threadIdentifier` = session id so a session's notifications stack; `relevanceScore` 1.0 for
  requests, 0.3 for finished.
- `apns-collapse-id` = request id. When answered on the Mac, the Mac sends the relay's dismiss for
  the same collapse id.
- Actions run in the background: the action handler (app delegate, background launch) posts
  through the shared outbox using the keychain token, with `Idempotency-Key: <requestID>:<kind>`. In the app, a tap after a refused or unknown attempt goes under `<requestID>:<kind>:a<n>`.
  On failure it posts a local notification "Couldn't reach MacBook Pro. Open to answer."
- Foreground: `willPresent` suppresses banners for the session on screen and turns others into
  the bottom accessory plus a `.warning` haptic instead of a banner.
- **Token verification:** the relay's silent `verify` push (protocol, Push payloads) is answered in
  `application(_:didReceiveRemoteNotification:)` with `POST /v1/device/verify` to the relay.

### 5.2 Notification Service Extension

1. Read the envelope from `userInfo["e"]`, take its 4-byte `keyId`, load that Mac's push key from
   the shared keychain, ChaCha20-Poly1305 open with `AAD = 0x01 ‖ keyId ‖ category ‖ collapseId ‖
   deviceId` (relay-and-release, Envelope). Failure: show "Side A needs you" with Open only, so
   nothing actionable comes from a payload we couldn't read.
2. Set title, subtitle, body, `threadIdentifier`, `interruptionLevel`, `relevanceScore`,
   `targetContentIdentifier` (= route), `userInfo` (request id, session id, `turnID`). Set
   `categoryIdentifier` to `REQUEST_SAFE` only when the category is `REQUEST` and the payload's
   `gate` is `lockScreen`; otherwise keep the category as sent. Decryption can only loosen
   `REQUEST` to `REQUEST_SAFE`.
3. Write the decrypted payload by request id into `shared.sqlite` (for the Live Activity and the
   Content Extension) and update the widget snapshot's counts there, in one transaction;
   `WidgetCenter.reloadTimelines` for the "needs you" widget kind.
4. Images: none in v1 (fetching over Tailscale inside the extension's time budget is unreliable).

### 5.3 Notification Content Extension

SwiftUI in a `UIHostingController`, sized by `preferredContentSize`. Categories `QUESTION`,
`PLAN`, `REQUEST_SAFE`, `REQUEST`, `REQUEST_DESTRUCTIVE`. It reads the decrypted payload from
the notification's `userInfo["p"]`, which the Service Extension sets (no SQLite read in the
extension); the `shared.sqlite` copy serves the Live Activity and widgets. A question or plan whose payload has `full: false` shows "Open to
answer" and the Open action only, never partial options.

- **Question:** header "Question 1 of 2", question text `.headline`, options as numbered rows
  (radius 12, `secondarySystemBackground`). Tapping an option posts that answer immediately for a
  single question, or advances for several (same pager logic, compact). The last row "Write your
  own…" switches to the text input action. After sending: a check and "Sent", then
  `extensionContext?.dismissNotificationContentExtension()` after 0.8 s.
- **Plan:** markdown (same renderer from the shared framework, without images), scrollable to
  ~400 pt; actions below are the category's.
- **Request:** the command in a mono block or a compact diff (first hunk), the project and account,
  the risk label when destructive.

```
┌─────────────────────────────────┐
│ SIDE A REMOTE              now  │
│ Question for you                │
│ side-a · Work                   │
├─────────────────────────────────┤
│ Question 1 of 2                 │
│ Where should the cache live?    │
│ ┌─────────────────────────────┐ │
│ │ 1  App Group                │ │
│ ├─────────────────────────────┤ │
│ │ 2  Caches directory         │ │
│ ├─────────────────────────────┤ │
│ │ ✎  Write your own…          │ │
│ └─────────────────────────────┘ │
├─────────────────────────────────┤
│ Open                            │
└─────────────────────────────────┘
```

### 5.4 Live Activity

One activity per Mac. Its lifecycle (start by push-to-start, update on any displayed change,
replacement before the 8-hour limit, token turnover, dismissal, end after 15 idle minutes) is
relay-and-release's [Live Activity](relay-and-release.md#live-activity).

**Counts only on the wire.** The attributes and content state are protocol's
`MacActivityAttributes`: attributes `{macID}` (a hash of the relay install id, never the Mac's
name); content state `{working, waiting, topRequest?, soonestReset?, tightestPercent?}`, where
`topRequest` is an opaque request id. They reach Apple and the relay in plaintext, so they never
hold words. **Every word comes from the phone's decrypted local cache**: the Mac's name from the
paired-Mac record matched by `macID`; the request headline, command, project, account, agent and
gate from the Service Extension's entry for `topRequest` in `shared.sqlite`; the limit's account
and window from the widget snapshot. When `topRequest` isn't in the cache (alert not delivered
yet, phone just rebooted), the activity says "1 needs you" and its buttons open the app.
`staleDate` = 30 minutes after the last update; stale views show "Updated 32 min ago".

Live Activity views are snapshots: they can't spin continuously. The "spinning disc" from
`remote.md` becomes a static disc glyph (custom SF Symbol, section 7.6) whose count changes use
`.contentTransition(.numericText())`. The disc only exists in the app's own drawing; no animated
GIF tricks.

- **Compact leading:** disc glyph (white). With something waiting: the disc gets a 6 pt amber dot
  at its upper right.
- **Compact trailing:** working count in mono ("3"), or amber "1" with `hand.raised.fill` when
  waiting.
- **Minimal:** disc, or the amber dot alone when waiting.
- **Expanded:**
  - leading: disc + "3 working" (`.caption.monospacedDigit()`),
  - trailing: tightest limit "5h 82%" mono with a 2 pt bar under it,
  - center: top waiting headline "Allow Bash" + project · account,
  - bottom: the command in one mono line, then `Button(intent: DenyRequestIntent(…))`
    **Deny** and **Allow** (amber). Allow is `AllowSafeRequestIntent` (runs locked) only when the
    cached request's gate is `lockScreen`; for `unlock` it is `AnswerRequestIntent`, whose
    `authenticationPolicy` is `.requiresAuthentication`; for `biometric` the buttons are **Deny** and
    **Open**. Nothing waiting: the two most recent working sessions with their steps, from the
    widget snapshot when it is under 10 minutes old, else the counts alone.
- **Lock Screen / banner:** row 1: disc + "3 working · 1 needs you" (`.headline`, the "needs you"
  part in amber); row 2: the top waiting headline + command in mono, with Allow / Deny buttons
  trailing by the same gate rules (as on Waymo's lock screen activity); row 3: tightest limit as a thin bar (Jomo
  reference) with "Work 5h 82% · resets 2:14" in mono `.caption`. Background: `.containerBackground`
  system default (the activity follows the Lock Screen's glass), tint `activityBackgroundTint(nil)`.
- **Watch Smart Stack** (`supplementalActivityFamilies([.small])`): disc + counts + amber dot.
- After an Allow from the activity, the intent updates the activity locally to "Allowed" at once
  (`Activity.update`) and the next push confirms.

```
Compact          ( ◉ ·········· 3 )      waiting: ( ◉• ·········· ✋1 )
Minimal          ( ◉ )                   waiting: ( • )

Expanded
╭──────────────────────────────────────────╮
│ ◉ 3 working                  5h 82% ▂▂▂▂ │
│        Allow Bash · side-a · Work        │
│ swift test --filter Sync                 │
│  ┌──────────────┐  ┌──────────────┐      │
│  │     Deny     │  │    Allow     │      │
│  └──────────────┘  └──────────────┘      │
╰──────────────────────────────────────────╯

Lock Screen
┌──────────────────────────────────────────┐
│ ◉  3 working · 1 needs you               │
│ Allow Bash               [Deny] [Allow]  │
│ swift test --filter Sync                 │
│ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▭▭▭  Work 5h 82% · 2:14│
└──────────────────────────────────────────┘
```

### 5.5 Widgets

Data comes from the widget snapshot in `shared.sqlite` (written by the app, the Service Extension
and intents, each in its own transaction) and
timeline reloads triggered by pushes. If WidgetKit push updates are available on the deployment
target, the relay also sends widget pushes; otherwise the Service Extension's reload covers it.

| Widget | Families | Content |
|---|---|---|
| **Limit** | systemSmall, accessoryCircular, accessoryInline | Small: the LCD plate (section 7.1) filling the widget: account name, the tightest window, percent large in mono, "resets 2:14". Circular: `Gauge` `.accessoryCircularCapacity` with the percent. Inline: "Work 5h 82% · 2:14". Configurable account (AppIntent configuration: In use, or a specific account). |
| **Sessions** | systemMedium, systemLarge, accessoryRectangular | Medium: "3 working · 1 needs you" header, then up to 3 rows (status glyph, title, step in mono). Large: up to 7 rows grouped Needs you / Working. Rectangular: counts + top waiting headline. Rows deep-link to the session. No Allow buttons on Home Screen widgets (too easy to tap by accident); answering stays in notifications, the Live Activity and the app. |
| **Accounts** | systemMedium | Up to 4 accounts as small ring pairs with mono percents (Jomo-style). |

Widgets support the tinted and clear Home Screen modes: rings and glyphs use `widgetAccentable()`
on the fill, LCD plate falls back to a plain fill in accented mode. Stale data shows "as of 1:02".

### 5.6 Control Center controls

- **Needs you** (`ControlWidgetButton`): label "Side A", value "1 waiting" or "3 working", symbol
  disc or `hand.raised.fill`; opens the app to the top waiting request (`OpenIntent` with a
  `Route`).
- **New Session** (`ControlWidgetButton`): opens the New session sheet.
Both also work as Lock Screen controls and the Action button.

### 5.7 App Intents

All in `SideARemoteShared` so the app, widgets and Live Activity share them.

| Intent | Notes |
|---|---|
| `AnswerRequestIntent` (`LiveActivityIntent`) | param: request id; allows. `authenticationPolicy = .requiresAuthentication`, so a locked phone asks to unlock first. Refuses when the cached gate is `biometric` ("Open Side A Remote to review"). Runs without opening the app. |
| `AllowSafeRequestIntent` (`LiveActivityIntent`) | param: request id; allows. `authenticationPolicy = .alwaysAllowed`; refuses unless the cached request's gate is `lockScreen`. |
| `DenyRequestIntent` (`LiveActivityIntent`) | param: request id. `.alwaysAllowed`: denying is always safe. |
| `OpenSessionIntent` (`OpenIntent`) | target: `SessionEntity`. |
| `NewSessionIntent` | params: project (`ProjectEntity`), agent, prompt, account (optional). Siri: "Start a Claude session in side-a with Side A Remote". Opens the sheet prefilled unless "Start right away" is set. |
| `ReplyToSessionIntent` | params: session, text. Uses the same `auto` mode. `.requiresAuthentication`. |
| `GetTightestLimitIntent` | returns `LimitSummary` with a snippet view (the LCD plate). "What's my Claude limit?" |
| `ListWaitingIntent` | returns waiting requests, for Shortcuts automations. |

Entities: `MacEntity`, `SessionEntity` (also `IndexedEntity` so recent sessions appear in
Spotlight), `ProjectEntity`, `AccountEntity`, each with an `EntityQuery` reading the App Group
snapshot in `shared.sqlite` first, then the Mac. `AppShortcutsProvider` exposes New Session, Check limits and Open
waiting request.

---

## 6. Native motion and haptics

### 6.1 Rules

1. **Every expandable thing opens and closes with a mechanic iOS already has.** Pushes, zoom
   transitions, sheets with detents, disclosure, glass morphs, menus, context menus, swipe
   actions. If SwiftUI has a mechanic for it, we use that and don't draw our own. Known
   exceptions, each because nothing native exists: the streamed-word fade (section 4.3) and the
   image viewer's zooming scroll view (a `UIScrollView`, section 4.12).
2. **Tap to open, gesture to close.** Every open has a close by gesture, not only by button: a
   zoom push drags down or edge-swipes back, a sheet swipes down, a disclosure taps closed, a
   menu dismisses on a tap outside. Done / ✕ buttons are a second way, never the only one.
3. **Interactive and interruptible.** Nothing disables hit testing while it animates. A
   half-dragged sheet or zoom can be let go either way; a disclosure tapped twice mid-spring
   retargets from where it is. No sequencing with `DispatchQueue.asyncAfter`; the one timed
   step (the question card's 250 ms advance) is a cancellable `.task`.
4. **System curves only.** `withAnimation(.smooth)` for expand / collapse and scrolling,
   `.snappy` for small state swaps (selection, toggles), and whatever the system uses for pushes,
   sheets and glass. No hand-tuned `response` / `dampingFraction`, no `timingCurve`, no keyframes.
   The springs in earlier drafts of this spec (1.0 / 0.32 and so on) are replaced by `.smooth`.
5. **Reduce Motion.** System transitions handle themselves (the zoom becomes a cross-fade, sheets
   still slide). Our own `withAnimation` calls read `accessibilityReduceMotion` and pass `nil`;
   `.push` transitions become `.opacity`.
6. **Haptics** only through `.sensoryFeedback(_:trigger:)` tied to state (section 4).

### 6.2 Open and close, interaction by interaction

| Interaction | Open | Close | API |
|---|---|---|---|
| Tool row → step page (4.3) | tap; the page zooms out of the row | drag down, edge swipe, back button; flies back into the row | `NavigationLink(value:)`; `.matchedTransitionSource(id: step.id, in: ns)` on the row; `.navigationTransition(.zoom(sourceID: step.id, in: ns))` on the page |
| Diff card / code block → full page (4.3) | tap the header or "Show all" | same as above | same, keyed by the block id |
| File chip → file page (4.3) | tap | same as above; QuickLook content dismisses the same way | zoom push; `.quickLookPreview(_:)` inside for PDFs and other types |
| Image thumbnail → viewer (4.12) | tap | drag down (follows the finger), edge swipe, back | zoom push |
| Subagent step inside a Task page | tap | drag down returns to the Task page, again to the transcript | nested zoom pushes on the same `NavigationStack` |
| Thinking row (4.3) | tap; the text unfolds in place | tap again | `DisclosureGroup(isExpanded:)` with a custom `DisclosureGroupStyle` (the v0 row look; the chevron turns 90° in the same transaction), toggled in `withAnimation(.smooth)` |
| Step group (4.3) | tap | tap | same; child rows use `.transition(.opacity)`, no stagger |
| Answered request / answered question line (4.3, 4.6) | tap | tap | same |
| Request card → approval sheet (4.5) | tap the card | swipe down, or answer | `.sheet(item:)`, `presentationDetents([.medium, .large])`, `presentationDragIndicator(.visible)`; the card is the `matchedTransitionSource` and the sheet content uses `.navigationTransition(.zoom)` so it grows out of the card |
| Question card paging (4.6) | pick an option | tap a summary line to go back | `.transition(.push(from: .trailing / .leading))` in `withAnimation(.smooth)` |
| Plan approval (4.7) | tap the plan card | swipe down | sheet, `.large`, zoom from the card |
| `+` → Add sheet (4.4) | tap `+` | swipe down, or pick something | `.sheet` with `presentationDetents([.medium, .large])`, zoom from the `+` circle; pushes inside its own `NavigationStack` for Model and Effort |
| Composer mic ↔ send ↔ stop (4.4) | state change | state change | one `GlassEffectContainer`; `glassEffectID` per shape; `.contentTransition(.symbolEffect(.replace))` on the symbol |
| Follow-mode button (4.3) | scroll up past 40 pt | tap it (scrolls down), or scroll to the bottom | in the composer's `GlassEffectContainer` with its own `glassEffectID`; `.glassEffectTransition(.matchedGeometry)` so it buds off the composer; circle ↔ capsule is the same glass shape resizing |
| Slash suggestions (4.4) | type `/` | delete it, tap outside, Esc | glass panel in the composer's container, `.glassEffectTransition(.materialize)` |
| Title menu (4.3) | tap the title | tap outside, pick | `toolbarTitleMenu` |
| Session Info (4.3) | Title menu → Session Info | swipe down | `.sheet`, `[.medium, .large]` |
| Toolbar `⋯` menu, stop button menu | tap / long press | tap outside, pick | `Menu`; `Menu(primaryAction:)` for the stop button |
| Long press on a message, tool row, session row | long press lifts it with a preview | release outside, tap outside | `.contextMenu(menuItems:preview:)` |
| Swipe actions on session rows (4.2, 4.14) | swipe | swipe back, tap elsewhere | `List` `.swipeActions(edge:allowsFullSwipe:)`; full swipe off for anything that sends or quits |
| Swipe actions on transcript rows (iOS 27) | swipe | same | `swipeActionsContainer()` on the `LazyVStack`, `.swipeActions` on the row |
| Preview dev server (4.14) | Preview :port | swipe down when the page is at its top, Done | `.sheet`, `.large`, SwiftUI `WebView` with a pinning navigation delegate |
| Confirmations (Quit, Stop Server, Remove worktree) | tap the action | tap outside, Cancel | `confirmationDialog`, anchored to its source (iOS 26 shows it as a popover from the button); iOS 27 `confirmationDialog(item:)` |
| Rename | Title menu or context menu → Rename… | Cancel, swipe | `.alert` with a `TextField` |
| Send a Message (4.14) | context menu, swipe, toolbar | swipe down, Send | `.sheet` with `presentationDetents([.height(240), .medium])`, field focused on appear |
| Restart Fresh (4.14) | toolbar, health card, context menu | swipe down; once edited, swipe asks first | `.sheet`, `.large`; `interactiveDismissDisabled(edited)` plus a "Discard changes?" `confirmationDialog` |
| Session row → transcript | tap | edge swipe, back | plain `NavigationLink` push; no zoom (a row isn't the same object as a screen) |
| Navigation bar on scroll | scroll down | scroll up | soft scroll edge effect (default on iOS 26); iOS 27 `toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)` |

### 6.3 Other moments

| Moment | Motion | Reduce Motion | Haptic |
|---|---|---|---|
| Row inserted (Sessions, transcript) | `.transition(.opacity.combined(with: .offset(y: 8)))` in `.smooth` | `.opacity` | none |
| Request arrives (foreground) | row moves to Needs you, accessory slides up (system) | fade | `.warning` |
| Allow | sheet dismisses; inline card folds to a line | fade | `.success` |
| Deny | same | fade | `.impact(.rigid)` |
| Question option picked | checkmark `.symbolEffect(.replace)`, card pushes after 250 ms | fade | `.selection` |
| Tool step running | glyph `.symbolEffect(.variableColor.iterative)`; label swaps tense with `.contentTransition(.opacity)` | static glyph | none |
| Thinking live | `brain` glyph `.symbolEffect(.pulse)`, seconds tick with `Text(timerInterval:)` | static | none |
| Streaming text | words fade in over 120 ms (custom, see 6.1) | chunks appear | none |
| Copy | icon swaps to checkmark with `.contentTransition(.symbolEffect(.replace))` | same | `.success` |
| Ring fill | sweep from 0 in `.smooth(duration: 0.8)` | static | none |
| Numbers change | `.contentTransition(.numericText())` | same | none |
| Composer send ↔ stop | glass morph via `glassEffectID` | cross-fade | `.impact(.light)` on send |
| Pairing success | glass card morph + `checkmark` `.symbolEffect(.drawOn)` | fade | `.success` |
| Restart Fresh runs | sheet dismisses; the transcript route is replaced by the new session's | fade | `.success` |

---

## 7. Visual tokens

### 7.1 Colour (asset catalog, each with light, dark and high-contrast variants)

| Token | Light | Dark | Use |
|---|---|---|---|
| `amber` (AccentColor) | `#F29D0B` | `#FFB23E` | fills: needs-you glyph, Allow button tint, badges, rings 75–96% |
| `amberText` | `#9A5B00` | `#FFC266` | amber text on plain backgrounds (4.5:1); high contrast `#7A4700` / `#FFD596` |
| `done` | system `green` | system `green` | ready glyph, toggles, diff additions |
| `destructive` | system `red` | system `red` | risk labels, destructive buttons, rings ≥97%, diff removals, failing flag |
| `diffAdd` | green @ 14% | green @ 18% | added line background (bar at 100%) |
| `diffRemove` | red @ 12% | red @ 16% | removed line background |
| `lcdPlate` | `#C9CEBF` | `#1D2420` | LCD readout background |
| `lcdInk` | `#283029` | `#B9CBA4` | LCD text (dark mode reads as backlit) |
| `terminalBackground` | `#0F1312` | `#0F1312` | terminal, always dark (from Side A's deck ink) |
| `terminalForeground` | `#E4E7E3` | `#E4E7E3` | terminal default text |
| Surfaces | `systemBackground`, `systemGroupedBackground`, `secondarySystemGroupedBackground`, `secondarySystemBackground` (code, diffs), fills `secondary/tertiary/quaternarySystemFill` | | no custom greys |
| Text | `label`, `secondaryLabel`, `tertiaryLabel` | | |

Amber rules: amber marks what needs the user and the action that answers it. It isn't used for
links (label color, underlined), toggles (green), the send button (label color), navigation or
selection. Claude and Codex never get colours; they differ by glyph. The Mac island's terracotta
for "waiting" stays on the Mac (open question 2).

### 7.2 Type (Dynamic Type styles only; no fixed sizes outside the terminal)

| Role | Style |
|---|---|
| Screen titles | `.largeTitle` bold (system large title) |
| Sheet headline / question | `.title3.weight(.semibold)` |
| Row title | `.body.weight(.semibold)` |
| Transcript body | `.body`, line spacing 3 |
| Headings in markdown | h1 `.title3.bold`, h2 `.headline`, h3+ `.subheadline.weight(.semibold)` |
| Tool row verb / target | `.subheadline.weight(.medium)` / `.subheadline.monospaced()` |
| Mono metadata, step line | `.footnote.monospaced()` |
| Code, diffs | `.callout.monospaced()` in code sheets, `.caption.monospaced()` in diff cards |
| Numbers everywhere | `.monospacedDigit()` on proportional text, or `.monospaced()` |
| LCD | `.title3.monospaced().weight(.semibold)`, uppercase, tracking +0.5 |
| Terminal | SF Mono 13 pt default, user 10–18, not Dynamic Type |

### 7.3 Spacing

4 pt grid: 4, 8, 12, 16, 20, 24, 32. Screen margins come from the system (16 on iPhone); list
rows 12 pt vertical; transcript blocks 12 apart, turns 24 apart, tool rows 0 apart (their 36 pt
min height carries rhythm); floating glass sits 16 pt from edges and 8 pt above the keyboard.

### 7.4 Corner radii (all `.continuous`)

| | Radius |
|---|---|
| Chips, capsule buttons, status capsules | capsule |
| Composer container | 24 (concentric with the screen corner via `ConcentricRectangle` where it touches edges) |
| Account cards | 22 |
| User message, question card | 20 |
| Option list inside the question card, request inline card, file chip | 14 |
| Letter badge on an option | 6 |
| LCD plate | 14 |
| Code, diff, mono blocks | 12 |
| Thumbnails | 10 |
| Inline code | 4 |
| Sheets, tab bar, toolbars | system |

### 7.5 Glass rules

1. Glass only on the floating layer: tab bar, toolbars, the composer, the bottom accessory,
   "N new" and "Back to chat" capsules, the terminal key bar, the image viewer's chrome, the
   scanner's buttons, and the pairing card over the camera.
2. Never on content: list rows, messages, tool rows, cards, diffs and code are plain surfaces.
   Cards are for objects only (a diff, a code block, a file chip, a question, a request, a health
   note); assistant prose never sits in a card (section 4.3). The buttons inside a request or
   question card are the one exception to glass-only-floating, so Allow and Send Answers look
   the same inline and in the sheet.
3. Never glass on glass. Adjacent glass elements share a `GlassEffectContainer` so they blend and
   morph.
4. Tappable custom glass uses `.interactive()`. Prominent actions use `.glassProminent` with amber
   tint; everything else uses `.glass` with the default monochrome foreground.
5. Sheets get glass from the system at partial detents; don't add backgrounds to them.
6. Reduce Transparency is handled by the system for system glass; our few custom surfaces
   (LCD, cards) are opaque already.

### 7.6 Iconography (SF Symbols, `.hierarchical` rendering unless noted)

| Meaning | Symbol |
|---|---|
| Needs you | custom: amber filled ring (`circle.circle.fill` look), in lists; `hand.raised.fill` in Live Activity |
| Working | `progress.indicator` with `.symbolEffect(.rotate, options: .repeat(.continuous))` (a native symbol effect, not a hand-drawn arc); static `ellipsis.circle` under Reduce Motion |
| Ready / done | `checkmark.circle.fill` (green) |
| Idle | `circle` (tertiary) |
| Stuck / looping | `exclamationmark.triangle` (secondary) |
| Failing | `exclamationmark.triangle.fill` (red) |
| Claude / Codex | `asterisk` / `chevron.left.forwardslash.chevron.right` (as on the Mac) |
| Hosted | `terminal` |
| Disc (Side A) | custom symbol `sidea.disc`: a circle with a hub, exported from the Mac's disc drawing, 3 weights |
| Read / Write / Edit | `doc.text` / `doc.badge.plus` / `pencil.line` |
| Bash | `apple.terminal` |
| Grep / Glob | `magnifyingglass` / `folder.badge.questionmark` |
| WebFetch / WebSearch | `globe` / `globe.badge.chevron.backward` |
| Task / subagent | `person.2` |
| MCP tool | `puzzlepiece.extension` |
| Screenshot / image | `photo` |
| TodoWrite | `checklist` |
| Plan | `list.bullet.clipboard` |
| Question | `questionmark.bubble` |
| Thinking | `brain` |
| Step group | `square.stack.3d.up` |
| Message / Next step / After this turn / Stop before next step / Take back | `text.bubble` / `clock` / `text.append` / `pause.circle` / `arrow.uturn.backward` |
| Restart fresh | `arrow.trianglehead.counterclockwise` |
| Preview dev server / stop server | `safari` / `stop.circle` |
| Fork / Resume | `arrow.triangle.branch` / `play.circle` |
| Pin / Archive | `pin` / `archivebox` |
| Keep awake / Clean up | `cup.and.saucer` / `trash.slash` |
| Dictation | `mic` |
| New session | `square.and.pencil` |
| Interrupt | `stop.fill` |
| Attach | `plus` |
| Project | `folder` ; git root `arrow.triangle.branch` ; worktree `arrow.triangle.branch` with `plus` badge |
| Account | `person.crop.circle` |
| Mac | `laptopcomputer` / `desktopcomputer` by model |
| Copy / Save / Share | `doc.on.doc` / `square.and.arrow.down` / `square.and.arrow.up` |
| Tailscale off | `network.slash` |

### 7.7 App icon

Built with Icon Composer as a layered `.icon` so it gets Liquid Glass, dark, tinted and clear
modes for free.

- **Background:** Side A's deep green-black (`#1F2624`, the Mac icon's 0.12/0.15/0.14), flat.
- **Foreground layer 1:** the disc player seen straight on, simplified to a flat silver circle
  with a soft rim; no "SIDE A" or small print (illegible at 60 pt).
- **Layer 2:** the LCD window as a pale green-grey rounded rectangle, with a single segmented
  "A" in LCD ink.
- **Layer 3:** the orange play key (`#E04A1A`, the Mac's deck orange) as the only saturated spot.
- Same family as the Mac icon, recognisably a sibling; the phone version is flatter and front-on
  rather than the 3D three-quarter render. No phone or remote-control metaphor: the subtlety is
  the point.
- Dark mode: background goes near-black, disc darkens to graphite, LCD glows faintly. Tinted:
  the disc and LCD take the tint, the play key stays the accent shape.

---

## 8. Build order

Aligned with the milestones in `remote.md`. Each step ends with screenshots of every screen in
light and dark, at default and AX3 text sizes, compared against the references, before moving on.

### M0 · Look (internal TestFlight)

1. `project.yml` with all five targets (extensions as stubs), App Group, keychain group,
   entitlements, `scripts/ios-testflight.sh` dry run.
2. Design system: tokens, asset catalog colours, glyphs (status, disc symbol), LCD plate, rings,
   haptic helpers, previews with fixture data for every component.
3. `SideARemoteKit`: `RemoteClient` (REST), `SyncEngine` with polling (no socket yet), snapshot
   persistence; `AppModel` and stores fed by fixtures, then by a real Mac.
4. Onboarding and pairing (setup's flow): welcome, Tailscale screen, QR scanner (camera-denied
   card), pinned TLS delegate, pairing with the comparison code, every failure card, Test
   Connection; keychain storage.
5. Sessions home: sections, rows, glyphs, Mac chip, empty / stale / offline states, group by.
6. Transcript read-only: markdown renderer (native `AttributedString` walk), user turns, tool rows,
   thinking rows, step groups, code blocks and the zoom-pushed step and code pages, file chips,
   "earlier messages" fold, polling refresh.
7. Accounts: LCD readout, ring cards, account detail, stale handling.
8. Settings shell: Macs, About, Acknowledgements.
9. App icon (Icon Composer), launch screen (plain `systemBackground`).

### M1 · Answer

1. Events WebSocket with `lastSeq` replay and cursor-based gap repair; connection states and
   banners.
2. Outbox in `shared.sqlite` with idempotency; approval sheet (by gate; `.biometric` with Face ID),
   inline request card, bottom accessory, foreground haptics and VoiceOver announcements.
3. Question card (inline, section 4.6) and plan approval.
4. Composer: reply / follow-up / note with take-back, interrupt, the Add sheet with Model and
   Effort, dictation, slash suggestions, hardware keyboard.
5. Steer from rows and the toolbar: Send a Message, Stop Before Next Step, Take Back (section 4.14).
   Health flags on rows and the health card.
6. Streaming transcript: delta merge, paced reveal, follow mode and "N new".
7. Diffs (Claude `structuredPatch`, Codex unified diff) and the full diff page.
8. Images: thumbnails, zoom-transition viewer, Copy / Save / Share, paging.

### M2 · Notify

1. Push registration with `NotificationPrefs`, relay install id, X25519 key exchange at pairing,
   the relay's token verification push.
2. Notification Service Extension (decrypt, gate to `REQUEST_SAFE`, store, widget reload).
3. Categories and background action handling through the shared outbox; collapse to "Answered
   on Mac"; foreground suppression.
4. Notification Content Extension: question, plan, request.
5. Live Activity: counts-only content state with words from the local cache, all presentations,
   push-to-start, the three answer intents by gate, stale handling, Watch small family.
6. Widgets (Limit, Sessions, Accounts, Lock Screen families) and the two Control Center controls.
7. App Intents and entities, App Shortcuts, Spotlight indexing.
8. Settings › Notifications and Live Activity, synced to the Mac.

### M3 · Start

1. New session sheet: chips, project picker, recents, worktree, account, idempotent start.
2. Terminal: SwiftTerm view, glass key bar with sticky ctrl and arrow trackpad, pinch font size,
   `/ws/term` with acked input and predictive echo, resize rules and "Sized for MacBook Pro".
3. Photo attachments (composer and new session): picker, camera, paste, downscale, upload.
4. Continue on iPhone (confirmation, then the session reappears as hosted), Resume on ended
   sessions.
5. In-house syntax highlighting for common languages.
6. Only in Side A (section 4.14), as its endpoints (section 4.15) land: History with pins,
   rename, archive and fork lineage, Search, Resume / Fork from the phone; Restart Fresh with the
   handoff sheet; ports, Preview, Stop Server, Quit Session, Quit Idle; the Mac sheet with Keep
   Awake.
   (M4 per protocol: Autopilot decisions, Move Now, worth at API prices, incidents, Clean Up.)

### M4 · Codex and offline

1. Codex everywhere: glyphs, Codex `FileChange` diffs, Codex hook trust row, Codex models in chips.
2. LAN mode, with Wi-Fi addresses from the QR code rather than Bonjour ("Pair over Wi-Fi"), the same pinned key as over
   Tailscale, the Mac chip showing "Wi-Fi" vs "Tailscale".
3. Remote approvals log (Settings › Macs › Mac › "Answered from this iPhone").
4. Autopilot, worth, incidents and Clean Up (protocol's M4 rows).
5. iPad split view polish, landscape terminal, keyboard shortcuts overlay.
6. App Store: screenshots from fixture data, privacy nutrition label ("Data Not Collected"),
   review notes (Tailscale requirement, a demo Mac for review: see open question 6), the
   site's download section.

---

## 9. Open questions

1. ~~Search endpoint.~~ Settled: `GET /v1/search` (protocol, M3).
2. **Amber vs the Mac's terracotta.** The Mac island marks "waiting" with Claude's terracotta
   (`0.85, 0.47, 0.34`). The plan asks for one amber accent on the phone. Keep amber on the
   phone only, or move the Mac to the same amber so "needs you" means one colour across both?
3. **iOS 26 minimum.** Confirm 26.0, or raise to 27 at launch (M4) if that's when the App Store
   release actually happens and 27 adoption is high by then.
4. ~~Allow from the Lock Screen without unlocking.~~ Settled by `AllowGate`: only the safe
   allowlist (reads, searches, edits inside the project) runs locked; every command, MCP or
   unknown tool and permission-widening answer needs unlock; destructive needs Face ID in the app.
5. **Model and effort on non-hosted sessions.** The chips need typing into the TUI, so they're
   hidden for non-hosted sessions. Is that acceptable, or should the Mac relay `/model` through
   the hook path somehow?
6. **App Review.** Reviewers need a Mac with Side A and Tailscale. Options: a demo mode with
   fixture data behind a hidden gesture on the welcome screen, or a reviewer tailnet with a hosted
   Mac. Demo mode also helps screenshots.
7. **Analytics.** Side A's Mac app has an opt-in. Recommendation for Remote: collect nothing in
   v1 ("Data Not Collected"), revisit later.
8. **Notification previews on the Lock Screen.** Commands and project names can be sensitive.
   Default to the system's "Show Previews: When Unlocked"? It's a system setting, so the app can
   only recommend it during onboarding.
9. **Markdown tables and task lists.** Verify `AttributedString` `.full` parsing on real Claude
   output early in M0. If tables fall short, adopt `swift-markdown` then rather than later.
10. ~~Preview reach.~~ Settled: Preview is served through Side A's own pinned listener, never a
    Tailscale Serve path, so nothing is exposed tailnet-wide; it goes down when the sheet closes
    and after 30 minutes.
11. **Restart Fresh while working.** The spec asks before stopping a working session. Should the
    phone instead offer "Restart after this step" (stop mail, then restart once it stops)?
