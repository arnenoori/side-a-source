# Side A Remote protocol (v1)

The wire contract between Side A on the Mac (`RemoteServer`) and Side A Remote on the iPhone. It
fills in the API section of [the plan](../remote.md); where the two disagree, this file wins and the
plan gets a one-line pointer here.

Status: spec, October 2026. Nothing here is built yet.

## Conventions

- **Transport.** TLS 1.3 terminated by Side A itself, on one port. The Mac's `NWListener` presents a
  self-signed P-256 identity kept in Side A's Keychain; the phone pins the SHA-256 of that key's
  SubjectPublicKeyInfo (`fp`, from the pairing QR code or confirmed by the pairing code, see
  Pairing) in a `URLSession` server-trust delegate and accepts no other key, whatever the name or
  chain says. Tailscale is only the network: no Tailscale Serve, no `ts.net` certificate, no
  MagicDNS or HTTPS-certificate requirement on the tailnet.
- **URLs.** One origin per address, `https://<host>:47800` (Side A Dev: 47900), where `<host>` is
  the Mac's Tailscale address (`100.x.y.z`), its MagicDNS name when the tailnet has one, or in LAN
  mode its LAN address or `<name>.local`. Every address serves the same thing with the same pinned
  key. REST is `https://<host>:47800/v1/…`; the two WebSockets are `wss://<host>:47800/v1/ws/events`
  and `wss://<host>:47800/v1/ws/term/{name}`, upgraded on the same connection type as REST (see
  [mac-server](mac-server.md#listeners)). There is no second port and no channel field: the path
  picks the channel.
- **JSON.** UTF-8, camelCase keys, Swift's synthesized `Codable` names. No `Date` in any wire type:
  every moment is a `Double` of seconds since 1970 in a field ending in `At` (the existing models
  already do this, e.g. `UsageWindow.resetsAt`). Optional fields are omitted, never `null`, when
  encoding; decoders accept both. `Set`-valued fields encode as arrays sorted by raw value, so
  fixtures are byte-stable. Acronyms keep Swift's spelling (`sessionID`, `requestID`, `turnID`);
  the bridge's snake_case output never reaches the wire unadapted (see Twins).
- **Tagged unions.** `ServerEvent`, `ClientMessage` and `TermControl` all use the same framing:
  `{"type": "<name>", "data": {…}}` (`data` omitted for cases without a payload). `IslandAction`
  and `RemoteAnswer` are tagged by `kind` inline.
- **Ids.** Strings. Request ids are lowercased UUIDs. Session keys are described under
  `RemoteSession`. Image ids are lowercase hex SHA-1.
- **Open enums.** Any enum that may grow is a `RawRepresentable` string struct (see `OpenEnum`
  below), so an older client keeps the unknown value instead of failing the whole decode. Closed
  enums (`AgentProvider`, `ReplyMode`) are ordinary enums and never gain cases within v1.
- **Size caps.** JSON request bodies ≤ 1 MiB; uploads ≤ 20 MiB. Any single string in a list
  response or an event is cut at 64 KiB; the object then carries `truncated: true` and a full fetch
  exists for it.
- **Headers on every call.** `Authorization: Bearer <token>` (all but `GET /v1/hello` and the
  `/v1/pair` routes), `X-SideA-Protocol: 1`, `X-SideA-Client: SideARemote/<version> (<build>; iOS <x>)`.
  Every response carries `X-SideA-Protocol` and `X-SideA-Epoch`.
- **Device token.** `"sa1_" + base64url(32 random bytes)` without padding (47 characters). The
  prefix exists so secret scanners can recognise a leaked token; clients treat the whole string as
  opaque and never parse it.

### What this defends against

Remote can't defend against a same-user agent with full filesystem access: such a process can
already replace Side A's hook scripts or impersonate the hook socket and approve its own requests
without touching Remote. Within that boundary, the protocol defends against:

- **Other devices on the tailnet and the LAN.** Every call needs a device token; tokens exist only
  after a pairing the user approved on the Mac.
- **Browsers and DNS rebinding.** `Host` must be one of the Mac's own addresses, any `Origin` or
  `Sec-Fetch-Site` header is refused, no CORS headers are ever sent.
- **A replacement listener.** A process that binds the port after Side A quits can't present the
  pinned key (it lives in Side A's Keychain), so the phone never sends it a token.
- **A lost phone that was never paired, or was revoked.** It has no token, or a token the Mac no
  longer accepts. A paired phone that is lost is handled by Revoke, and its Lock Screen can only
  approve the safe allowlist (see `AllowGate`).
- **An agent that reads the screen during pairing.** It can see the code and submit it, but it
  can't make its attempt show the same six-digit comparison code as the user's phone (see Pairing).

The Mac's side of this is in [mac-server](mac-server.md#threat-model).

## Package layout

```
Packages/SideAProtocol/
  Package.swift
  Sources/SideAProtocol/          wire types; Foundation only
    Exports.swift                 OpenEnum, Timestamp, Cursor
    Agents.swift                  AgentProvider (moved)
    Island.swift                  IslandAction, IslandQuestion, IslandRisk (moved) + Codable
    Usage.swift                   UsageWindow, ExtraUsage, AccountUsage (moved)
    Sessions.swift                RemoteSession, FinishedSession, HostedSession, RemoteProject
    Requests.swift                RemoteRequest, RemoteSuggestion, RemoteAnswer, RequestResolution
    Talk.swift                    RemoteReply, ReplyResult, InterruptResult, Upload
    Transcript.swift              TranscriptPage, TranscriptMessage, TranscriptTool, ImageRef, FileDiff
    Accounts.swift                RemoteAccount
    Pairing.swift                 Hello, Capability, PairRequest, PairPending, PairResponse, DeviceInfo,
                                  RelayInfo, PairingTranscript (the comparison code), PushRegistration
    Options.swift                 AgentOptions (models, efforts, commands per agent)
    Extras.swift                  the "Only in Side A" types (History, Handoff, MacState, Autopilot, …)
    Events.swift                  EventEnvelope, ServerEvent, ClientMessage, StateSnapshot
    Terminal.swift                TermControl, TermFrame
    Errors.swift                  APIError, ErrorCode
  Sources/SideARemoteKit/         client: HTTP, WebSockets, SyncEngine, Outbox; Foundation only
  Sources/SideAProtocolFixtures/  a loader (test support, shipped in no app)
    Fixtures/v1/…                 the fixture files, as the target's resources
  Tests/SideAProtocolTests/
  Tests/SideARemoteKitTests/
```

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideAProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SideAProtocol", targets: ["SideAProtocol"]),
        .library(name: "SideARemoteKit", targets: ["SideARemoteKit"]),
        .library(name: "SideAProtocolFixtures", targets: ["SideAProtocolFixtures"]),
    ],
    targets: [
        .target(name: "SideAProtocol"),
        .target(name: "SideARemoteKit", dependencies: ["SideAProtocol"]),
        .target(name: "SideAProtocolFixtures", resources: [.copy("Fixtures")]),
        .testTarget(name: "SideAProtocolTests", dependencies: ["SideAProtocol", "SideAProtocolFixtures"]),
        .testTarget(name: "SideARemoteKitTests", dependencies: ["SideARemoteKit", "SideAProtocolFixtures"]),
    ]
)
```

- No dependencies. Swift 6 language mode, so every wire type is `Sendable` and checked.
- `SideARemoteKit` builds on macOS too, so its tests run with `swift test` on the Mac and in CI
  without a simulator. It uses `URLSession` and `URLSessionWebSocketTask` only.
- The root `Package.swift` adds `.package(path: "Packages/SideAProtocol")`; `SideACore` depends on
  the `SideAProtocol` product, `SideATests` also on `SideAProtocolFixtures`. Sparkle stays out of the
  package.
- `Sources/SideACore/Exports.swift` holds one line, `@_exported import SideAProtocol`, so no file
  in `SideA` changes its imports.
- The iOS app (`apps/ios/project.yml`) depends on `SideARemoteKit` (which re-exports nothing; the
  app imports both) and SwiftTerm.

### What moves and what gets a twin

Moved types keep their names and public API; they become `Codable` where they weren't, and gain
public memberwise initializers (they had internal ones, which a test used through `@testable`).
They also gain `Hashable` where they were only `Equatable` (`IslandQuestion`, `IslandAction`,
`UsageWindow`, `ExtraUsage`, `AccountUsage` at `Models.swift:114`), because the wire containers
below are `Hashable` and synthesized conformance needs every member to be.

| Type | Now | After |
|---|---|---|
| `AgentProvider` | SideACore/Models | **moves** unchanged |
| `IslandAction` | SideACore/Island | **moves**, gains `Codable` and `headline` / `detail` (moved off `IslandRequest`, which forwards to them) |
| `IslandQuestion`, `.Option` | SideACore/Island | **move**, gain `Codable` and `answerText(picked:other:)` (the rule `IslandView.answer` uses today) |
| `IslandRisk` | SideACore/Island | **moves**, gains `Codable` as a string; `assess(_:)` stays in SideACore as an extension (the rules are Mac policy) |
| `UsageWindow`, `ExtraUsage`, `AccountUsage` | SideACore/Models | **move**; `hitting(_:at:)` and `forFable` stay in SideACore as extensions (Autopilot policy) |
| `RemoteAccount` (iCloud sync, "elsewhere") | SideACore/Models | **renamed** `SyncedAccount`, same JSON, to free the name |
| `IslandAgent` | SideACore/Island | stays; gains `var provider: AgentProvider` |
| `IslandRequest` | SideACore/Island | stays (hook decoding); twin `RemoteRequest` |
| `Island.Pending` | SideA/Island | stays; `id` is the request id on the wire (already a stable `UUID`) |
| `IslandSuggestion` | SideACore/Island | stays (raw rule JSON never leaves the Mac); twin `RemoteSuggestion` |
| `IslandAnswer` | SideACore/Island | stays (hook line); twin `RemoteAnswer`, mapped on the Mac |
| `Island.Ready` / `IslandFinish` | SideA, SideACore | stay; twin `FinishedSession` |
| `LiveSession` | SideA/SessionModels | stays (bridge decoding); twin `RemoteSession` |
| `SessionMessage`, `SessionDetail` | SideA/SessionModels | stay; twins `TranscriptMessage`, `TranscriptPage` |
| `SessionInfo` | SideA/SessionModels | stays; twin `PastSession` |
| `Account` + `AccountUsage` | SideACore | stay; twin `RemoteAccount` |

Twins are built only on the Mac, in `Sources/SideA/Remote/Wire+Builders.swift`, from the app's
own state. The phone never sees a hook payload, a Keychain slot, a pid it could act on, or a raw
permission rule.

The bridge's `show --format remote` output is a bridge DTO, not a wire type: it is snake_case,
carries `ts` instead of `at` and raw tool `input` instead of a parsed `action`. `Wire+Builders`
decodes it into `BridgeTranscriptPage` (explicit `CodingKeys`, so `session_id` becomes
`sessionID`, not `.convertFromSnakeCase`'s `sessionId`) and adapts it: `ts → at`,
`input → IslandAction` through the island's own parser, `src` dropped.

## Wire types

### Shared basics

```swift
public typealias Timestamp = Double           // seconds since 1970
public typealias SessionKey = String
public typealias RequestID = String           // lowercased UUID

/// An enum that may grow: unknown values decode and round-trip unchanged.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {}
public extension OpenEnum {
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self))! }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// Opaque pagination cursor. Clients store and send it back; they never parse it.
public struct Cursor: Codable, Hashable, Sendable { public let raw: String }   // encodes as a bare string
```

### Moved island types

```swift
public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable { case claude, codex }

public enum IslandRisk: Int, Sendable, Comparable, Codable {
    case low, normal, destructive
    // Encodes "low" | "normal" | "destructive". An unknown string decodes as .destructive:
    // a value the client does not understand must never make a request easier to approve.
}

public struct IslandQuestion: Sendable, Hashable, Codable {
    public struct Option: Sendable, Hashable, Codable {
        public let label: String
        public let description: String?
        public var recommended: Bool { get }      // computed, not encoded
        public var title: String { get }          // computed, not encoded
    }
    public let question: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool
    /// Picked labels then typed text, joined with ", ": what goes back to Claude Code.
    public func answerText(picked: [String], other: String?) -> String
}

public enum IslandAction: Sendable, Hashable, Codable {
    case command(String)
    case edit(path: String, removed: String, added: String)
    case write(path: String, content: String)
    case patch(files: [String], text: String)
    case read(path: String)
    case fetch(String)
    case search(String)
    case mcp(server: String, tool: String, arguments: String)
    case question([IslandQuestion])
    case plan(String)
    case other(tool: String, arguments: String)

    public var headline: String { get }
    public var detail: String { get }
}
```

`IslandAction` JSON is tagged by `kind`:

```json
{"kind": "command",  "command": "npm test"}
{"kind": "edit",     "path": "/x/a.swift", "removed": "…", "added": "…"}
{"kind": "write",    "path": "/x/a.swift", "content": "…"}
{"kind": "patch",    "files": ["a.swift"], "text": "*** Begin Patch…"}
{"kind": "read",     "path": "/x/a.swift"}
{"kind": "fetch",    "url": "https://…"}
{"kind": "search",   "query": "TODO in Sources"}
{"kind": "mcp",      "server": "github", "tool": "create_issue", "arguments": "{…}"}
{"kind": "question", "questions": [{"question": "…", "header": "…", "options": [{"label": "…", "description": "…"}], "multiSelect": false}]}
{"kind": "plan",     "plan": "## Plan…"}
{"kind": "other",    "tool": "NotebookRun", "arguments": "{…}"}
```

Rule for later kinds: every new kind also carries `tool` and `arguments`. A decoder that does not
know the kind decodes `.other(tool: tool ?? kind, arguments: arguments ?? "")`, so no new case is
ever needed on an old phone.

### RemoteSession

One row per live agent process, plus hosted tmux sessions that have no agent process yet.

```swift
public struct SessionStatus: OpenEnum { public let rawValue: String }
// .working ("busy" and "shell" in Claude Code's registry), .waiting, .idle, .finished, .starting, .exited,
// .unknown (the Mac couldn't establish the state, e.g. a Codex rollout tail with no turn marker; it
//  authorizes nothing: no Continue on phone, no interrupt, no `auto` typing)

public struct SessionFlag: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum { public let rawValue: String }   // stuck, loop, failing, bloated, unsent
    public let kind: Kind
    public let text: String
}

public struct SessionAbility: OpenEnum { public let rawValue: String }
// .transcript, .followUp, .note, .interrupt, .type (hosted: free text at any time),
// .terminal, .continueOnPhone, .end, .replyTerminal (a Codex session outside Side A's panes, reached
// through Codex's shared app server: a reply shows in its terminal as the user's message),
// .replyInbox (a Claude session outside Side A's panes, idle or finished, whose inbox hook is
// waiting: a reply wakes it and Claude Code shows the model the text as a note, not as user input),
// .settingsModel "settings.model", .settingsEffort "settings.effort", .settingsMode "settings.mode",
// .settingsFast "settings.fast" (POST …/settings takes that field now), .turnDiff (GET …/turns/{turnID}/diff),
// .compact and .review (idle only; Codex thread/compact/start and review/start)

public struct RemoteSession: Codable, Hashable, Sendable, Identifiable {
    public let id: SessionKey
    public var conversationID: String?        // Claude session id or Codex thread id; transcripts are keyed by it
    public var agent: AgentProvider
    public var title: String                  // the same title the Mac shows
    public var cwd: String?
    public var project: String                // SessionStore.projectName: a worktree names its main repo
    public var branch: String?
    public var worktree: Bool
    public var accountID: String?
    public var accountName: String?
    public var model: String?                 // the same as settings.model, for phones that predate settings
    public var effort: String?                // the same as settings.effort
    public var status: SessionStatus
    public var waitingFor: String?            // Claude Code's own words, e.g. "permission"
    public var statusAt: Timestamp?           // when status last changed
    public var lastReplyAt: Timestamp?        // for "date by last reply" and sorting
    public var step: String?                  // the current step line
    public var context: Int?                  // tokens
    public var contextPercent: Double?        // 0–100: Claude's statusline used_percentage, Codex last tokens / window
    public var flag: SessionFlag?
    public var cost: Double?                  // USD: Claude's statusline or transcript, Codex threadUsage.estimatedUsageUsdMicros
    public var openRequests: [RequestID]      // in arrival order
    public var mail: MailState?               // a note or stop not yet taken
    public var hosted: String?                // tmux session name when hosted
    public var abilities: Set<SessionAbility>
    public var headless: Bool                 // claude -p / SDK runs: listed, never offered Reply
    public var ports: [ListeningPort]?        // M3 (`ports`); nil from a Mac that doesn't report them
    public var memoryBytes: Int?              // M3
    public var abilityReasons: [String: String]?  // why an ability the phone shows is off, keyed by its raw value
    public var settings: SessionSettings?     // capability `settings`
    public var turnID: String?                // the running turn, else the last: what .turnDiff reads
    public var plan: TurnPlan?                // the turn's live plan list
    public var backgroundTasks: Int?          // subagents and background shells still running
}

public struct PermissionMode: OpenEnum { public let rawValue: String }
// Claude: .default, .plan, .acceptEdits, .auto, .dontAsk, .bypassPermissions.
// Codex: .default, .plan (collaborationMode), .never (approvalPolicy), .dangerFullAccess (sandboxPolicy).
// `raises`: .bypassPermissions, .never, .dangerFullAccess and any value the phone doesn't know.

public struct SessionSettings: Codable, Hashable, Sendable {   // nil fields: the Mac couldn't read them
    public let model: String?
    public let effort: Effort?
    public let mode: PermissionMode?
    public let fast: Bool?                    // Claude's fast mode; nil for Codex
}

public struct TurnPlan: Codable, Hashable, Sendable {   // Codex turn/plan/updated, Claude's todos
    public let explanation: String?
    public let steps: [TranscriptTodo]
}

public struct MailState: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum { public let rawValue: String }   // note, stop
    public let kind: Kind
    public let at: Timestamp
}
```

- **`id`.** The conversation id when known; otherwise `pid-<pid>-<started>` (process start in whole
  seconds, as `LiveSession.started`), or `tmux-<name>` for a hosted session still starting. When a
  session's conversation id first appears or changes (`/clear`, resume), the server sends
  `session.remove{id: old, replacedBy: new}` then `session.upsert` for the new key. All session
  paths accept any of the three forms.
- **`abilities`** is the server's answer to "what can I do here right now", so the phone never
  re-derives Mac rules. Examples: a non-hosted Claude session that is working has `.note`,
  `.interrupt`, `.followUp` (queued); a finished one with a waiting Stop hook has `.followUp`.
  Codex sessions take notes but not stops: the Mac leaves `runtime/mail/codex/<thread id>.json`
  and the island's Codex PostToolUse hook hands it over as `additionalContext` after the next
  tool (by thread id, since a turn's hooks run in the TUI or the shared app server). That needs
  the island's Codex hooks installed and trusted in Codex, and a thread started after that (a
  thread loads its hooks when it starts; an older one leaves the note waiting, as its `mail`
  shows). Codex 0.163 fails a PreToolUse `continue: false`, so a stop is still refused.
  `.interrupt` for a Codex session outside Side A's panes needs `.replyTerminal`.
- **`abilityReasons`** names why an ability is off in plain words ("Claude is working. Try when
  it's idle.", "Codex has no fast mode."). The phone shows the control disabled with that line;
  an ability with no reason is simply not offered.
- **`settings`** is what the session runs with now. Claude: model, `effort.level` and `fast_mode`
  from the side-a-live statusline, mode from the transcript's `permission-mode` record or the
  hooks' `permission_mode`. Codex: `ThreadSettings` (`thread/settings/updated`, `thread/read`).
  `model` and `effort` stay filled for older phones.
- The pid is not on the wire. The phone acts on sessions only through these paths.

### FinishedSession

The twin of `Island.Ready`: a turn that ended with nothing left running.

```swift
public struct FinishedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: SessionKey { sessionID }
    public let sessionID: SessionKey
    public let turnID: String                // Ready.id (Island.swift:31), lowercased UUID; immutable, one per finished turn
    public let title: String
    public let summary: String               // IslandFinish.summary: first line of prose, ≤ 160 chars
    public let at: Timestamp
    public let canFollowUp: Bool             // a Stop hook is waiting (or the session is hosted)
}
```

`turnID` names this finished turn and no other. A follow-up to a finished session must carry it
(`RemoteReply.turnID`); if the session has since started and finished another turn, the Mac
answers 409 `turn_changed` instead of waking the newer waiter. A reply queued from turn A's
notification can therefore never land on turn B.

Finished sessions are listed while the Mac keeps them (two hours, newest eight), whether or not
the island's Finished panel is on: with a paired device, the Remote switch keeps Stop waiters.

### RemoteRequest

The twin of `Island.Pending`.

```swift
public struct AnswerKind: OpenEnum { public let rawValue: String }
// .allow, .always, .deny, .terminal, .answers, .approvePlan,
// .allowMode (listed only: the Mac takes AnswerBody.mode with .allow; never an answer's own kind)

public struct RemoteSuggestion: Codable, Hashable, Sendable, Identifiable {
    public let id: String        // first 16 hex of SHA-256 of the suggestion's rule JSON
    public let title: String     // "Always allow Bash(npm run test:*) in this project"
}

public struct RemoteRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: RequestID
    public let sessionID: SessionKey?
    public let agent: AgentProvider
    public let tool: String
    public let action: IslandAction
    public let headline: String              // computed on the Mac; shown when `action` is .other on an old phone
    public let detail: String
    public let reason: String?
    public let risk: IslandRisk              // presentation only: the label and colour
    public let riskReason: String?
    public let gate: AllowGate?           // what an Allow needs on the phone; decides, risk doesn't
    public var allowGate: AllowGate { get }  // computed, not encoded: gate ?? .unlock; the phone reads this, never `gate`
    public let suggestions: [RemoteSuggestion]   // empty when risk == .destructive or agent == .codex
    public let answers: Set<AnswerKind>      // which answers the Mac accepts for this request
    public let title: String                 // session title, project, or agent name, as the island shows
    public let project: String?
    public let accountName: String?
    public let headless: Bool
    public let arrivedAt: Timestamp
    public let handBackAt: Timestamp?        // Codex and headless: handed back to the terminal then
    public let truncated: Bool               // some string in `action` was cut; GET /v1/requests/{id} has it whole
    public let modes: [PermissionMode]?      // what .allowMode may switch to, best first (capability answers.mode)
}
```

`answers` encodes the island's rules once, on the Mac: questions accept `.answers`, `.deny`,
`.terminal`; plans accept `.approvePlan`, `.deny`, `.terminal`; other requests accept `.allow`,
`.deny`, `.terminal`, and `.always` only when a suggestion exists and the risk isn't destructive.

```swift
public struct AllowGate: OpenEnum { public let rawValue: String }
// .lockScreen  Allow works from a locked phone (notification action, Live Activity button)
// .unlock      Allow needs the phone unlocked (notification action with .authenticationRequired,
//              an App Intent with .requiresAuthentication, or the app)
// .biometric   Allow only inside the app, after Face ID, with an X-SideA-Confirm signed by the
//              confirm key (Signed confirms)
// A missing gate means .unlock. An unknown value decodes as .biometric, the same rule as an
// unknown IslandRisk: a value the phone doesn't understand never makes approval easier.
```

The gate is an explicit allowlist computed on the Mac (`AllowGate.of(_:project:)` in
SideACore), not derived from `IslandRisk`, whose rules are heuristics for the label only:

| Request | Gate |
|---|---|
| `IslandRisk` destructive (any kind) | `.biometric` |
| `.read` of a path inside the session's project (cwd or its git root), not a secret path | `.lockScreen` |
| `.search` | `.lockScreen` |
| `.edit`, `.write`, `.patch` whose every path is inside the project and none is a secret path or agent configuration | `.lockScreen` |
| `.command` (any shell), `.mcp`, `.fetch`, `.other`, an unknown kind | `.unlock` |
| any answer that widens permissions: `.always`, `approvePlan(acceptEdits: true)` | `.unlock` (never offered for `.biometric`) |
| `.approvePlan(acceptEdits: false)` | `.unlock` |
| `.answers` (questions), `.deny`, `.terminal` | no gate |
| `.allow` with `AnswerBody.mode` | the request's gate, and `.biometric` when the mode `raises` |

With `confirm.signed`, the Mac enforces gates by signature ([Signed confirms](#signed-confirms)):
`.biometric` needs the confirm key, `.unlock` the unlock key or the confirm key, `.lockScreen` none.
Without it, a phone's `confirmDestructive: true` is the old check (422 `needs_confirm`).
`confirmDestructive` still decodes, but a Mac with `confirm.signed` ignores it. The gate is
recomputed when the answer arrives; if it rose since the phone showed the request, the answer is
409 `gate_changed` and the phone refetches and reviews again.

### RemoteAnswer

```swift
public struct QuestionAnswer: Codable, Hashable, Sendable {
    public let question: String      // IslandQuestion.question, verbatim (it is the key Claude Code expects)
    public let picked: [String]      // option labels, verbatim, "(Recommended)" included
    public let other: String?        // typed text
}

public enum RemoteAnswer: Codable, Hashable, Sendable {
    case allow(confirmDestructive: Bool)
    case always(suggestionID: String)
    case deny(message: String?)
    case terminal
    case answers([QuestionAnswer])
    case approvePlan(acceptEdits: Bool)
}
```

JSON: `{"kind": "allow", "confirmDestructive": false}`, `{"kind": "always", "suggestionID": "…"}`,
`{"kind": "deny", "message": "…"}`, `{"kind": "terminal"}`,
`{"kind": "answers", "answers": [{"question": "…", "picked": ["…"], "other": "…"}]}`,
`{"kind": "approvePlan", "acceptEdits": true}`.

The Mac maps it to `IslandAnswer`: `.always` looks the suggestion up by id; `.answers` builds
`[question: answerText(picked:other:)]` with the request's stored input; `.approvePlan` passes the
stored input. The phone never sends tool input back. This is the only answer schema: the Mac's
`RemoteAnswer.resolve` (mac-server) implements exactly this table and these refusals.

| Answer | Becomes | Refused (422 `invalid_answer`, `details.reason`) when |
|---|---|---|
| `allow` | `.allow` | not in `answers` (`not_allowed`, e.g. a question or a plan); gate `.biometric` without `confirmDestructive: true` (`needs_confirm`); with `confirm.signed`, a missing or bad `X-SideA-Confirm` is 401 `confirm_required` / `confirm_invalid` instead, and a risen gate is 409 `gate_changed` |
| `always{suggestionID}` | `.always(suggestion)` | not in `answers` (`not_allowed`); unknown id (`unknown_suggestion`) |
| `deny{message?}` | `.deny(message)`, trimmed to 2,000 characters | never |
| `terminal` | `.terminal` | never |
| `answers[…]` | `.answers([question: answerText], input:)` | not a question (`not_allowed`); a `question` that isn't one of the request's, a label that isn't one of its options, or two labels on a single-select question (`unknown_option`); a question with no answer (`incomplete`); `other` over 2,000 characters (`too_long`) |
| `approvePlan{acceptEdits}` | `.approvePlan(input:, acceptEdits:)` | not a plan (`not_allowed`) |

```swift
public struct RequestResolution: Codable, Hashable, Sendable {
    public struct By: OpenEnum { public let rawValue: String }
    // .mac (island or notification), .device, .terminal (answered in the CLI), .handedBack (Codex timeout),
    // .sessionEnded, .turnFinished, .autoAnswered (the Mac answered by itself after a minute,
    // AutopilotState.answersRecommended; `answer` is .answers or .approvePlan)
    public let requestID: RequestID
    public let by: By
    public let deviceID: String?     // when by == .device
    public let deviceName: String?
    public let answer: AnswerKind?   // nil when not answered by a person or by .autoAnswered
    public let at: Timestamp
}
```

### Talk

```swift
public enum ReplyMode: String, Codable, Sendable { case auto, followUp, note, keys }

public struct Key: OpenEnum { public let rawValue: String }
// "enter", "esc", "tab", "up", "down", "left", "right", "ctrl-c", "backspace", or one printable character

public struct ReplySubmit: OpenEnum { public let rawValue: String }   // .queue (the next turn: Tab in Codex, Enter in Claude Code), .steer (into the running turn: Enter in Codex; Claude treats it as .queue)

public struct RemoteReply: Codable, Hashable, Sendable {
    public let text: String          // may be empty only in .keys mode
    public let mode: ReplyMode
    public let keys: [Key]?          // .keys mode only; hosted sessions only
    public let submit: ReplySubmit?  // hosted and replyTerminal sessions; missing means queue on a hosted session, steer on a replyTerminal one
    public let attachments: [String] // Upload ids (Upload.id), never paths
    public let turnID: String?       // required when the session is finished: FinishedSession.turnID
}

public struct InterruptRequest: Codable, Hashable, Sendable {
    public struct When: OpenEnum { public let rawValue: String }   // .now, .nextStep
    public let when: When            // body optional; absent means .now
}

public struct ReplyResult: Codable, Hashable, Sendable {
    public struct Delivery: OpenEnum { public let rawValue: String }
    // .typed (pasted into the hosted pane, Enter sent), .followUp (handed to the waiting Stop hook),
    // .queued (delivered when the session next finishes), .note (left as mail), .inbox (left in a
    // replyInbox session's inbox; its hook takes it within a second)
    public let delivery: Delivery
    public let sessionID: SessionKey
}

public struct InterruptResult: Codable, Hashable, Sendable {
    public struct Method: OpenEnum { public let rawValue: String }
    // .escape (hosted), .stop (mail), .turnInterrupt (replyTerminal: Codex's app server interrupted the turn)
    public let method: Method
}

public struct Upload: Codable, Hashable, Sendable {
    public let id: String
    public let path: String          // where it is on the Mac, for the prompt
    public let mime: String
    public let bytes: Int
}
```

#### Delivery table

The one table for what a reply does. Mac-server and hosting implement it; the phone's composer
picks its placeholder from it. Rows are checked top to bottom; "Claude"/"Codex" only where they
differ. Every cell is a `ReplyResult.delivery` or an error.

| Session state | Hosted | `auto` | `followUp` | `note` | `keys` |
|---|---|---|---|---|---|
| has an open request (`waiting`) | either | 409 `session_waiting` | 409 `session_waiting` | Claude: `.note`; Codex: `.note` with its mail hooks on, else 409 `cannot_deliver` | hosted: sent; unhosted: 409 `not_hosted` |
| `unknown` | either | 409 `cannot_deliver` | 409 `cannot_deliver` | 409 `cannot_deliver` | hosted: sent |
| working, Codex with `replyTerminal` | no | `.typed` (steers the turn) | `.queued` (Codex's own queue) | 409 `cannot_deliver` | 409 `not_hosted` |
| idle or finished, Codex with `replyTerminal` | no | `.typed` (starts a turn) | `.typed` | 409 `cannot_deliver` | 409 `not_hosted` |
| working | yes | Claude: `.typed` (Claude Code queues a message submitted mid-turn); Codex: 409 `cannot_deliver` until hosting open question 7 settles it | Claude: `.queued`; Codex: 409 `cannot_deliver` | Claude: `.note`; Codex: `.note` with its mail hooks on, else 409 `cannot_deliver` | sent |
| working | no | Claude: `.note`; Codex: 409 `cannot_deliver` | Claude: `.queued`; Codex: 409 `cannot_deliver` | Claude: `.note`; Codex: `.note` with its mail hooks on, else 409 `cannot_deliver` | 409 `not_hosted` |
| finished, Stop hook waiting | either | `.followUp` | `.followUp` | 409 `cannot_deliver` | hosted: sent; unhosted: 409 `not_hosted` |
| idle (or finished with no waiter), Claude with `replyInbox` | no | `.inbox` | `.inbox` | `.inbox` | 409 `not_hosted` |
| idle (or finished with no waiter) | yes | `.typed` | `.typed` | 409 `cannot_deliver` | sent |
| idle (or finished with no waiter) | no | 409 `cannot_deliver`, `details.hint = "continueOnPhone"` | same | same | 409 `not_hosted` |

- `.queued` is the island's `queue`: delivered through the Stop waiter when the turn ends, at most
  5 per session (a sixth is 409 `cannot_deliver`, `details.hint = "queueFull"`). It needs a Stop
  hook that waits, which only Claude's does. The queue survives a relaunch. If the session ends or
  its turn ends with a hook that can't wait, the text is lost: `finished.resolve` with reason
  `queueDropped`, and a `health` push quoting it. An older phone only drops the session's finished row.
  With capability `replies.dropped`, `StateSnapshot.droppedReplies` keeps each such reply for 3 days
  (at most 20, on disk, across relaunches): `{id, sessionID, text?, at, device?, reason}`. `text` and
  `device` go only to the device that sent the reply, which takes the text back into the field once,
  by `id`, Queued turn or not. Other devices get `{id, sessionID, at, reason}` and do nothing. Reason
  `oldQueue` (an old queue file) has neither, for anyone: a phone gives back its own Queued turns in
  that session from before `at`. Hearing
  `finished.resolve` with `queueDropped`, a phone fetches `GET /v1/state` to learn which reply it was.
- `.followUp` and `.queued`-then-delivered both need `turnID` when the session is finished
  (missing: 422 `invalid_reply`; stale: 409 `turn_changed`).
- `keys` delivery is `ReplyResult.delivery = .typed`.
- For `replyTerminal` sessions `submit` applies too: a missing `submit` steers, and
  `submit: "queue"` behaves as `followUp`. While working they also list `.interrupt`
  (`InterruptResult.method = .turnInterrupt`) and `.followUp`.
- A reply that doesn't arrive sets `RemoteSession.flag = {kind: "unsent", text: …}`, quoting the
  first 80 characters of the message. For `replyTerminal`, that's a steer Codex dropped, still
  pending at an interrupt or unseen 30 s after the thread went idle: «Didn't reach Codex: "…"».
  For `replyInbox`, no hook took it from the inbox within 5 s, so the Mac took it back: «Didn't
  reach Claude: "…"». The next message that goes through clears it. It arrives in
  `session.upsert`; there is no separate event.
- Attachments: hosted sessions get each upload's Mac path pasted single-quoted (hosting, Images);
  everywhere else the paths are appended to the text, one per line.

### Transcript

```swift
public struct TranscriptRole: OpenEnum { public let rawValue: String }
// .user, .assistant, .tools, .thinking (Claude thinking, Codex reasoning summaries), .compact, .error

public struct TranscriptMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { seq }
    public let seq: Int                      // position in this generation, 0-based, dense
    public let uuid: String                  // transcript entry uuid (not unique: one entry can yield several messages)
    public let role: TranscriptRole
    public let at: Timestamp?
    public let model: String?
    public let durationMS: Int?              // .thinking: how long it thought
    public let inherited: Bool               // copied from the parent of a fork
    public let text: String?                 // markdown; nil for .tools
    public let textTruncated: Bool           // cut at 6,000 characters; GET …/messages/{seq} has it whole
    public let tools: [TranscriptTool]       // empty unless role == .tools
    public let images: [ImageRef]            // pasted images on a user message
}

public struct TranscriptTool: Codable, Hashable, Sendable, Identifiable {
    public struct Status: OpenEnum { public let rawValue: String }   // .running, .ok, .failed, .denied
    public let id: String                    // tool_use id (Claude) or call_id (Codex)
    public let name: String                  // "Bash", "Edit", "mcp__github__create_issue", "exec_command"
    public let summary: String               // one line, ≤ 400 chars (tool_summary in sessions.py)
    public let action: IslandAction?         // the same parse the island uses, cut to fit the 96 KiB tool budget
    public var status: Status
    public let startedAt: Timestamp?
    public var endedAt: Timestamp?
    public var output: String?               // result text, cut at 4,000 characters (see Size bounds)
    public var outputTruncated: Bool
    public var diffs: [FileDiff]             // Edit/Write structuredPatch, Codex FileChange
    public var images: [ImageRef]            // Read results, MCP and browser screenshots, Codex screenshots
    public let subagent: String?             // Task tool: the subagent's description
    public var agentID: String?              // the subagent's id once its result names it (opens its own transcript)
    public var todos: [TranscriptTodo]?      // TodoWrite, TaskCreate/TaskUpdate, Codex update_plan
    public let plan: String?                 // ExitPlanMode's plan
    public let group: Bool                   // Codex exec call with child commands: the phone folds it
    public let parent: String?               // on a Codex child command: the id of its exec, so the phone groups
                                             //  children under the right exec when several share a row
}

public struct TranscriptTodo: Codable, Hashable, Sendable {
    public struct Status: OpenEnum { public let rawValue: String }   // .pending, .inProgress, .completed
    public let text: String
    public let status: Status
    public let activeForm: String?
}

public struct ImageRef: Codable, Hashable, Sendable, Identifiable {
    public struct Source: OpenEnum { public let rawValue: String }
    // .read, .mcp, .pasted, .screenshot (Codex), .view (Codex ImageView / local_image), .other
    public let id: String                    // SHA-1 of the bytes; also the ETag
    public let mime: String
    public let bytes: Int
    public let width: Int?
    public let height: Int?
    public let source: Source
    public let name: String?                 // file name when it came from one
    public let seq: Int?                     // the transcript row it sits in (gallery listings; nil inside a row)
}

public struct FileDiff: Codable, Hashable, Sendable {
    public struct Change: OpenEnum { public let rawValue: String }   // .modified, .added, .deleted, .renamed
    public let path: String
    public let oldPath: String?
    public let change: Change
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiffHunk]
    public let truncated: Bool               // more than 2,000 lines; the rest is left out
}

public struct DiffHunk: Codable, Hashable, Sendable {
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    public let lines: [String]               // each starts with " ", "+", "-" or "\"
}

public struct TranscriptPage: Codable, Hashable, Sendable {
    public let sessionID: SessionKey
    public let generation: String            // changes when the Mac rebuilds this transcript's view
    public let messages: [TranscriptMessage] // ascending seq
    public let replaced: [TranscriptMessage] // after=: rows at or below the cursor's seq that changed since it (ascending)
    public let reset: Bool                   // the cursor was from another generation; this is the newest page
    public let before: Cursor?               // nil at the start of the conversation
    public let after: Cursor                 // continue forward: covers every row and revision in this page
    public let hasMoreAfter: Bool
    public let count: Int                    // messages in this generation
    public let inheritedBefore: Int          // inherited messages before the page (fork display)
    public let agentID: String?              // set when this page is a subagent's own transcript
}
```

- `seq` is the row index of the `views` table in `sessions.db`, which `update_view` only appends
  to. Consecutive tool calls merge into one `.tools` message, so a message can grow after it was
  first sent; the stream then sends `transcript.replace` for that `seq`.
- **Cursors are revision-aware and opaque.** The Mac encodes generation, seq and the session's
  revision counter (bridge, Cursors); the phone stores the latest `after` it was given (from a
  page or a `TranscriptDelta`) and sends it back unchanged, in REST paging and in `subscribe`. It
  never builds one. `after=c` returns new rows past `c` plus, in `replaced`, every older row whose
  revision is newer than `c`, so a tool result that landed while the phone was away is repaired.
- `generation` is new whenever `update_view` rebuilds a session's rows from offset 0 (the file's
  head changed). A cursor from another generation gets `reset: true` and the newest page over
  REST paging by `after`; `GET …/messages/{seq}?generation=` with a stale generation is 410.
- **Size bounds.** The bridge squeezes each tool under 96 KiB encoded (cutting `IslandAction`
  strings, `output` past 4,000 characters, and diff hunks, each marked truncated) and splits a run
  of tool calls into a new `.tools` row every 8 tools, so one row stays under about 800 KB and a
  long run of steps becomes several rows, never one unbounded one. `GET …/messages/{seq}` has
  everything. One event or page stays under the 1 MiB frame limit: the server packs
  `transcript.append` rows into events up to 900 KiB (a single large row travels alone) and
  shortens a page (setting `hasMoreAfter`) to stay under it.

### RemoteAccount

```swift
public struct RemoteAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let provider: AgentProvider
    public let ready: Bool
    public let active: Bool                  // holds the Mac-wide login for its provider
    public let usage: AccountUsage?          // moved type: windows, stale, extra, capacity
    public let readAt: Timestamp?            // when `usage` was read; the phone shows its age when stale
    public let sessions: Int                 // live sessions running on it
}
```

### HostedSession and RemoteProject

```swift
public struct HostedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String                  // sa-<project>-<4hex>
    public let agent: AgentProvider
    public let cwd: String
    public let project: String
    public let worktree: Worktree?
    public let sessionID: SessionKey?        // the RemoteSession running in it, once known
    public let createdAt: Timestamp
    public let macAttached: Bool
    public let viewers: Int                  // phone terminal viewers
    public let alive: Bool                   // pane still running (remain-on-exit keeps dead panes)
    public let exitStatus: Int?
}

public struct Worktree: Codable, Hashable, Sendable {
    public let path: String
    public let branch: String
}

public struct HostedAttention: Codable, Hashable, Sendable {   // event "hosted.attention"
    public struct Kind: OpenEnum { public let rawValue: String }   // .trust, .screen, .unsent
    public let name: String
    public let kind: Kind
    public let text: String                  // the last screen lines, or the trust dialog's question
}

public struct StartHosted: Codable, Hashable, Sendable {
    public let cwd: String                   // a RemoteProject.path
    public let agent: AgentProvider
    public let model: String?
    public let effort: String?
    public let worktree: Bool                // new worktree on sidea/<name>
    public let accountID: String?            // nil: whatever the shell line picks
    public let prompt: String?
    public let attachments: [String]         // Upload ids
    public let resume: String?               // conversation id to resume
    public let fork: Bool
}

public struct RemoteProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let gitRoot: String?
    public let branch: String?
    public let branches: [String]            // up to 20, most recently committed first
    public let lastUsedAt: Timestamp?
    public let liveSessions: Int
}

public struct PastSession: Codable, Hashable, Sendable, Identifiable {   // search results
    public let id: String
    public let agent: AgentProvider
    public let title: String
    public let project: String
    public let cwd: String?
    public let branch: String?
    public let firstAt: Timestamp?
    public let lastAt: Timestamp?
    public let snippet: String?
    public let snippetUUID: String?
}
```

### Pairing, hello, capabilities

This is the one pairing and hello schema. [mac-server](mac-server.md#pairing) implements the Mac
half, [relay-and-release](relay-and-release.md#key-exchange-at-pairing) uses the keys it produces,
[ios-app](ios-app.md#41-onboarding-and-pairing) draws it. Fixtures `Pair*.json`, `Hello.*.json`
and `PairingTranscript.*.json` (known keys with the expected comparison code) freeze it.

```swift
public struct Capability: OpenEnum { public let rawValue: String }
// Mac: "events", "transcript.stream", "images", "diffs", "answers.questions", "answers.plans",
//      "reply.note", "reply.followUp", "interrupt", "interrupt.nextStep", "uploads", "hosted",
//      "terminal", "continueOnPhone", "push", "liveActivity", "codex.live", "search", "options",
//      "history", "restart", "ports", "quit", "mac", "cleanup", "autopilot", "worth", "incidents",
//      "autopilot.toggle", "autopilot.answers", "accounts.use", "rotation", "update.check", "lan", "setup", "reply.terminal",
//      "reply.inbox"
// Phone: the same names for what it can render or use.
// With "reply.terminal", a Codex session that isn't hosted and lacks .replyTerminal was started
// outside Codex's shared server (--no-daemon, --profile, -c); the phone says "Started outside
// Codex's shared server: replies arrive only after it finishes."
// With "reply.inbox" the Mac has Claude's inbox hooks installed; a Claude session that isn't hosted
// and lacks .replyInbox has no hook waiting yet (it started before the install and hasn't finished
// a turn since).

public struct MacInfo: Codable, Hashable, Sendable {
    public let id: String                    // SHA-256 of machine-id, hex, first 16; the phone's key for this Mac
    public let name: String
}

public struct Hello: Codable, Hashable, Sendable {
    public let protocolVersion: Int          // 1
    public let minProtocol: Int
    public let maxProtocol: Int
    public let app: String                   // "0.6.0"
    public let build: Int
    public let mac: MacInfo
    public let capabilities: Set<Capability>
    public let minClientBuild: Int?          // below this the phone must update
    public let epoch: String                 // random per app launch
    public let serverTime: Timestamp
    public let paired: Bool?                 // set only when a valid token was sent
    public let remoteOn: Bool                // the Remote switch
    public let endpoints: Endpoints          // where this Mac listens now; the phone updates its copy on every hello over the pinned key
    public let keyID: String                 // first 8 bytes of the SPKI SHA-256, hex: which key is in use (reports, Test Connection)
}

public struct Endpoints: Codable, Hashable, Sendable {
    public let tailnet: String               // the primary address: the tailnet one ("100.101.12.4:47800"),
                                             // else the best LAN one when the Mac has no Tailscale
    public let name: String?                 // MagicDNS name with port, when the tailnet has MagicDNS
    public let lan: String?                  // "192.168.1.20:47800", only with Wi-Fi pairing on; = lans?.first, for older phones
    public let lans: [String]?               // every eligible LAN host:port, best first; only with Wi-Fi pairing on
}
// The phone tries `tailnet`, then `name`, then each of `lans` (or `lan` from a Mac that predates
// `lans`), de-duplicated. After every hello that passed the pinned TLS check it takes these
// addresses into its rotation and stores them, so a LAN address learned after pairing is used
// without relaunching or re-pairing.

public struct DeviceInfo: Codable, Hashable, Sendable {
    public let name: String                  // "Arne's iPhone"
    public let model: String                 // "iPhone18,1"
    public let system: String                // "iOS 27.0"
    public let app: String
    public let build: Int
    public let capabilities: Set<Capability>
}

public struct PairRequest: Codable, Hashable, Sendable {
    public let code: String                  // 8 Crockford base32 characters, from the QR; "-" and case ignored
    public let device: DeviceInfo
    public let deviceID: String              // 16 random bytes, base64url; also the relay's deviceId
    public let devicePublicKey: String       // X25519, 32 raw bytes, base64url
    public let deviceSecretHash: String      // base64url(SHA-256(deviceSecret)); deviceSecret = 32 random bytes, kept on the phone
    public let serverKeyHash: String         // base64url SHA-256 of the SPKI the phone saw on this connection
    public let replaces: String?             // an old deviceID of this phone (re-pairing); removed on Pair
    public let confirmKey: String?           // base64url X9.63 P-256 public key, 65 bytes; Secure Enclave, usable only after
                                             // Face ID (.biometryCurrentSet); verifies X-SideA-Confirm signed "c"
    public let unlockKey: String?            // the same for a key usable while the phone is unlocked; verifies signatures signed "u"
}

public struct PairPending: Codable, Hashable, Sendable {   // 202 from POST /v1/pair
    public let attemptID: String             // lowercased UUID; names this attempt in the wait call and on the Mac
    public let nonce: String                 // 16 random bytes from the Mac, base64url: the pairing nonce
    public let macPublicKey: String          // X25519 the Mac made for this device, 32 raw bytes, base64url
    public let expiresAt: Timestamp          // 60 s: approve on the Mac before then
}

public struct RelayInfo: Codable, Hashable, Sendable {
    public let url: String                   // "https://push.getsidea.com"
    public let installID: String             // the Mac's relay install id
    public let keyID: String                 // 4 bytes, base64url: names the push key both sides derived
}

public struct PairResponse: Codable, Hashable, Sendable {   // 201 from POST /v1/pair/{attemptID}/wait
    public let token: String                 // "sa1_" + base64url(32 random bytes); shown once
    public let deviceID: String
    public let mac: MacInfo
    public let relay: RelayInfo?             // nil when the Mac has no relay install yet (M0, M1)
    public let hello: Hello
}

public struct PushRegistration: Codable, Hashable, Sendable {
    public struct Environment: OpenEnum { public let rawValue: String }   // .sandbox, .production
    public let apnsToken: String             // hex
    public let bundleID: String              // the app's main bundle id; the relay's apns-topic, + ".push-type.liveactivity" for
                                             // Live Activity tokens. Debug: com.arnenoori.sidea.remote.dev
    public let apnsEnvironment: Environment  // fixed at build time: Debug sandbox, Release production; never read from the profile
    public let pushToStartToken: String?     // Live Activity
    public let activityTokens: [String: String]   // activity id → update token
    public let prefs: NotificationPrefs
}
// Decoding: a missing bundleID is "com.arnenoori.sidea.remote"; a missing apnsEnvironment falls back to the
// pre-rename key `environment`, then "production". Encoding writes only bundleID and apnsEnvironment.
// The relay accepts only allowlisted bundle ids and sends to api.sandbox.push.apple.com for sandbox.

public struct NotificationPrefs: Codable, Hashable, Sendable {
    public let requests: Bool, questions: Bool, plans: Bool, finished: Bool, limits: Bool
    public let timeSensitiveRequests: Bool
    public let liveActivity: Bool
    public let suppressWhileWatching: Bool   // "Don't notify while I'm watching the session"
}
```

**Flow.** The journey and its copy are in [setup](setup.md#pairing-sheet); this is the wire.

1. The Mac's pairing sheet makes a code and shows a QR code (format v2):
   `https://getsidea.com/pair#v=2&a=<tailnet address:port>[&l=<LAN address:port>[,<LAN address:port>…]]&fp=<base64url SHA-256 of the SPKI>&n=<Mac name>&m=<MacInfo.id>&t=<tailnet name>&c=<code>`
   (before 0.5.47 the Mac showed the same fragment under `sidea-remote://pair#…`; phones take both).
   `l` lists every LAN address, comma-separated, best first. With no Tailscale on the Mac, `a` is
   the best LAN address. A code whose `i`, `r` and `p` name the relay (see tunnel.md) may leave out
   `a` and `l`; `fp` is still required, and the relay origin must pass `RelayRoute.allowed`.
   One address serves REST and WebSocket, so there is no separate WebSocket URL. From the QR code
   the phone pins `fp` before sending anything. Before posting the code the phone says
   `GET /v1/hello` to `a`, then to each `l` address in turn, about 4 s each, under the same trust.
   It moves to the next address only when one can't be reached (cannot connect, cannot find host,
   timed out, connection lost, offline). Any HTTP answer, a hello, or a TLS key other than `fp`
   ends the search, and that address is used for the rest of pairing. The phone checks
   `minProtocol`, `maxProtocol` and `minClientBuild` from that hello before spending the code.
   Pairing is QR-only: the phone never offers a typed address or code, so it always has `fp` and
   pins it from the first byte. (Typed pairing, which accepted the key seen on the first hello, was
   removed after the security audit: its comparison code could be ground offline.) While the sheet
   stays open, an expired code is replaced automatically up to six times; each code still lasts
   five minutes and is single use.
2. The phone makes an X25519 key pair, a `deviceID` and a `deviceSecret`, and posts
   `PairRequest`. A right code with no attempt pending gets 202 `PairPending`. A wrong code
   counts a try (401 `bad_code`; the fifth burns the code, 410 `code_expired`). A right code while
   another attempt is pending voids the code and both attempts (409 `code_busy`; the Mac says "Two
   devices used this code. Start again."), so a racing attacker is visible, never silently first.
   With no sheet open: 404 `no_pairing`.
3. Both sides compute the **comparison code** (the SAS), a truncated hash of both public keys, the
   pairing nonce and the code:
   `c = SHA-256("sidea-pair-v1" ‖ len‖code ‖ len‖nonce ‖ len‖macPublicKey ‖ len‖devicePublicKey ‖ len‖spki [‖ len‖confirmKey ‖ len‖unlockKey])`,
   where each `len` is a 2-byte big-endian length, `code` is the normalized code as UTF-8
   (uppercase, `-` and whitespace removed, no Crockford mapping), the other fields are raw bytes,
   and `spki` is the TLS key hash (the Mac's own on the Mac; `fp` from the QR code on the phone);
   the code is `UInt64(bigEndian: c[0..<8]) % 1_000_000`, zero-padded to six digits shown
   `482 913`. When the phone sends either confirm key, both follow as raw X9.63 bytes, each
   zero-length when absent. With neither, the code is what it was before confirm keys, and a key
   stripped on the way changes the Mac's code but not the phone's. Push-key salts (installID,
   deviceID) and envelope AAD strings are UTF-8 text too. It does not depend on a TLS exporter. The
   phone shows it ("On MacBook Pro, check that the code matches, then click Pair."); the Mac's
   sheet names that exact attempt: **Pair “Arne’s iPhone”**, "Check that your iPhone shows
   **482 913**", with Codes Don't Match and Pair. An agent that read the code off the screen and
   raced the phone gets a different comparison code from the one on the user's phone, and a
   substituted TLS key changes it too.
4. The phone long-polls `POST /v1/pair/{attemptID}/wait` (held up to 60 s). On Pair: 201
   `PairResponse` (and, with `replaces`, the old record is removed). Cancel: 403 `declined`. Codes
   Don't Match: 403 `sas_mismatch`. Nobody clicked within 60 s: 408 `confirm_timeout`. Cancel on the phone:
   `DELETE /v1/pair/{attemptID}` voids the attempt, so it can no longer be confirmed on the Mac. No
   body, no token, always 204 whatever the attempt's state; a wait whose connection drops without a
   re-poll within 3 s does the same. The token exists in clear only in that response.
5. Both derive the push key (relay-and-release, Key exchange at pairing) from the X25519 shared
   secret, `installID` and `deviceID`, and throw away the X25519 private keys. The phone's own
   relay credential is `d1.<installID>.<deviceID>.<base64url(deviceSecret)>`; the Mac registers
   `deviceSecretHash` with the relay and never sees the secret.

The device then shows in Settings > Remote with Revoke. The Live Activity attribute `macID` is
`base64url(SHA-256("SideA macID v1\n" + installID)[0..<12])`, which the relay computes from the
install id when it starts the activity (`PushVector.request` pins the value).

`POST /v1/devices/rekey` repeats step 5 with fresh X25519 keys (body `{devicePublicKey}`, 200
`{macPublicKey, keyID}`) for the 30-day push-key rotation.

### Signed confirms

Header `X-SideA-Confirm: v1.<unix seconds>.<c|u>.<base64url DER ECDSA-SHA256>`, where `c` is the
confirm key and `u` the unlock key (both registered in `PairRequest`). The signed bytes are the
UTF-8 string `sidea-confirm-v1\n<macID>\n<deviceID>\n<purpose>\n<subject>\n<unix seconds>`. No
field may hold a newline, and request and session ids may not hold `:`.

| purpose | sent on | subject |
|---|---|---|
| `allow` | `POST /v1/requests/{rid}/answer` for a gated or destructive request (the phone may sign any allow; the Mac requires it for `.unlock` and `.biometric` gates) | `<rid>:allow`, `<rid>:always:<suggestionID>`, `<rid>:approvePlan:acceptEdits` or `:askEdits`, or `<rid>:answers:<base64url SHA-256 of the answers re-encoded as sorted-key JSON>` (the Mac hashes the answers it decoded, not the raw body) |
| `allow` (switching mode) | the same, with `AnswerBody.mode` | `<rid>:allowMode:<mode>` |
| `settings` | `POST /v1/sessions/{id}/settings`, always; `POST /v1/hosted` when `permissionMode` raises | `<sessionID>:<base64url SHA-256 of the SettingsChange as sorted-key JSON>`; for a start, `start:<base64url SHA-256 of the StartHosted as sorted-key JSON>` (the Mac hashes what it decoded) |
| `terminal` | the `/v1/ws/term` upgrade | the session's terminal name |
| `trust` | `POST /v1/hosted/{name}/trust`, always, and only by the confirm key (trusting a folder grants the agent access) | `<name>:<base64url SHA-256 of the hosted session's cwd>` |
| `account` | `POST /v1/accounts/{id}/use`, always, and only by the confirm key (the Mac-wide login moves every new session) | `<accountID>:use` |
| `autopilot` | `POST /v1/autopilot`, always, and only by the confirm key, on or off | `enabled:true` or `enabled:false`, from the `AutopilotChange` the Mac decoded |
| `autopilot` (answers) | `POST /v1/autopilot/answers`, always, and only by the confirm key, on or off | `answers:enabled:true` or `answers:enabled:false`, so a signature for Autopilot itself never turns this on |
| `rotation` | `POST /v1/accounts/{id}/priority`, `POST /v1/accounts/{id}/auto`, `POST /v1/rotation/swap-at`, `POST /v1/rotation/follow-fable`, always, and only by the confirm key | `<accountID>:priority:<level>`, `<accountID>:auto:true` or `:auto:false`, `swapAt:<percent>`, `followFable:true` or `:false`, each from what the Mac decoded |
| `keys` | a `.keys` reply, always, and only by the confirm key | `<sessionID>:<base64url SHA-256 of the keys' raw values joined by "\n">` |
| `settings` (start) | `POST /v1/hosted`, always | `start:<base64url SHA-256 of the StartHosted as sorted-key JSON>` |
| `action` | see below | `<action>:<target>:<base64url SHA-256 of the body as sorted-key JSON, or empty>` |

`action` calls, with `ConfirmAction` raw value and target:

| action | call | target | key |
|---|---|---|---|
| `reply` | `POST /v1/sessions/{id}/reply` (text) | session id | `ConfirmPolicy.reply`: unlock; confirm if the session's mode raises or is unknown, or the text starts with `!` |
| `restart`, `continue` | `POST /v1/sessions/{id}/restart`, `/continue` | session id | `ConfirmPolicy.session` |
| `quit`, `compact`, `review` | `POST /v1/sessions/{id}/quit`, `/compact`, `/review` | session id | unlock |
| `quitIdle` | `POST /v1/sessions/quit-idle` | empty | unlock |
| `endHosted` | `DELETE /v1/hosted/{name}` | name | unlock |
| `stopServer`, `preview` | `POST /v1/sessions/{id}/ports/{port}/stop`, `/preview` | `<id>:<port>` | unlock |
| `macSettings` | `POST /v1/mac/settings` | empty | unlock |
| `archive`, `restore` | `POST /v1/cleanup/archive`, `/restore` | empty | unlock |
| `removeWorktree` | `DELETE /v1/worktrees/{id}` | id | unlock |
| `moveNow` | `POST /v1/autopilot/move` | empty | unlock |

`Hello.capabilities` has `confirm.actions` once a Mac requires these. A phone seeing it asks for
Face ID before sending a call that needs the confirm key. A Mac without it ignores the extra header.
`Hello.minClientBuild` is 12: an authenticated call other than the open routes from an
`X-SideA-Client` with an older build gets 426 `upgrade_client`, and the phone shows its update
state. That header is a courtesy to old phones; the signatures are the enforcement.
A 401 is not recorded under its Idempotency-Key, so re-signing and resending runs the call.
`POST /v1/hosted` with a prompt starting with `-` (after whitespace) gets 422 `leading_dash`.

A `deny` answer and a `terminal` answer (handing the request back to the CLI) are never signed.
A settings change is signed by the unlock key, or by the confirm key after Face ID when it enters a
mode that `raises` (`confirm_required` `details.level = biometric` otherwise). The phone never
offers a raise from the Lock Screen, a notification action or a widget.
Every `/v1/ws/term` upgrade carries a fresh `terminal` signature by the confirm key (Face ID); the
Mac refuses the upgrade without one (`confirm_required`, `details.level = biometric`). The Mac
accepts a time within ±120 s and remembers signatures for 5 minutes to refuse replays.
A resend under an Idempotency-Key the Mac has already seen from the same device gets the stored
response before any signature check, so an outbox resend after a lost response isn't refused as a
replay. It replays the stored answer and never performs the action again.
`Hello.capabilities` has `confirm.signed` once the Mac enforces this; the phone signs whenever it
has keys, either way. Pairings made before confirm keys have none: the Mac answers
`confirm_required` with `details.hint = pairAgain`. The phone then offers Pair Again above its sessions, and so does a
phone with no keys of its own for a Mac with `confirm.signed`. A Pair Again makes its keys beside the ones in use and
signs with them only once the new pairing is saved, so a pairing that fails or is cancelled keeps signing.
SideAProtocol's `ConfirmMessage` and `ConfirmSignature` build and check these on both sides.

### Errors

```swift
public struct ErrorCode: OpenEnum { public let rawValue: String }

public struct APIError: Codable, Hashable, Sendable, Error {
    public let code: ErrorCode
    public let message: String               // plain English, safe to show
    public let retryable: Bool
    public let details: [String: String]?
}
// Body: {"error": {"code": "already_resolved", "message": "…", "retryable": false, "details": {…}}}
```

This envelope is the only error body anywhere in the API, REST and WebSocket alike; mac-server's
routes and the hosting endpoints return it too.

| Status | Codes |
|---|---|
| 400 | `bad_request`, `bad_json`, `missing_idempotency_key` |
| 401 | `unauthorized` (missing, unknown or revoked token), `bad_code` (pairing), `confirm_required` and `confirm_invalid` (`details.level`: `unlock`, `biometric`; `details.hint`: `pairAgain` when the device has no confirm keys; `details.reason`: `invalid`, `replayed` or `malformed`. Replay is keyed on the signed message and the signature's `r`, so a fresh signature in the same second is accepted and a copy, even a malleated one, is not) |
| 403 | `declined` (pairing cancelled on the Mac), `sas_mismatch` (Codes Don't Match), `forbidden_origin` |
| 404 | `not_found`, `session_not_found`, `request_not_found`, `image_not_found`, `port_not_found`, `no_pairing` (no pairing sheet open) |
| 408 | `confirm_timeout` (nobody clicked Pair within 60 s) |
| 409 | `already_resolved` (`details.by`, `details.answer`), `session_waiting`, `cannot_deliver` (`details.hint`), `not_hosted`, `in_progress`, `turn_changed`, `code_busy`, `outcome_unknown` (see Idempotency), `worktree_kept`, `nothing_to_move`, `account_not_ready` (the account is signed out or its login expired), `request_pending` (keys refused while a destructive request is open on the session), `gate_changed` (the gate rose between showing and answering; refetch and review) |
| 410 | `cursor_expired` (`messages/{seq}` with a stale generation), `code_expired` |
| 413 | `too_large` |
| 415 | `unsupported_media` |
| 421 | `bad_host` |
| 422 | `invalid_answer` (`details.reason`: `not_allowed`, `needs_confirm`, `unknown_suggestion`, `unknown_option`, `incomplete`, `too_long`), `idempotency_mismatch`, `invalid_reply` |
| 426 | `upgrade_client`, `upgrade_mac` |
| 429 | `rate_limited` (`Retry-After` header) |
| 503 | `remote_off`, `not_ready` (bridge starting), `tmux_missing` |

`retryable` is true only for 429, 503 and `in_progress`; clients retry exactly those (and network
failures) and nothing else.

## REST

### Rules for every endpoint

- **Auth.** `Authorization: Bearer sa1_…`. The server hashes it (SHA-256) and compares against
  the hashes in its Keychain in constant time. A missing, unknown or revoked token is 401 with no
  hint of which. Revoking a device also closes its sockets with 4401.
- **Idempotency.** Every `POST` and `DELETE` (the server allows only GET, POST and DELETE) except the `/v1/pair` routes (including `DELETE /v1/pair/{attemptID}`) requires
  `Idempotency-Key` (≤ 128 characters; the client sends a UUID from its outbox; missing is 400
  `missing_idempotency_key`). The server keeps one record per `(deviceID, key)`:
  `{method, path, body SHA-256, state, status, response, createdAt}`, for 24 hours, at most 1,000
  per device, **persisted** in `~/Library/Application Support/SideA/remote/idempotency.sqlite`
  (WAL, 0600; outside `runtime/`), not in memory, so it survives a relaunch while tmux sessions
  and hook waiters may not.
  - Before a handler causes any effect outside Side A (typing into tmux, starting a session,
    answering a hook, sending a signal), the record is written durably as `started`. After the
    effect, it is updated to `done` with the response.
  - A repeat with the same method, path and body hash replays a `done` record's response with
    `Idempotent-Replay: true`. A repeat while the first is still running in this process waits
    for it. The same key with another method, path or body is 422 `idempotency_mismatch`.
  - A `started` record left by an earlier process (Side A crashed or quit between the effect and
    the acknowledgment) is **ambiguous**: the repeat gets 409 `outcome_unknown`, never a second
    execution. The phone shows "This may or may not have reached the Mac" on the row it came
    from, with the session to check and a Retry that sends a new key. Nothing retries an
    ambiguous execution automatically.
- **Notification actions** use `Idempotency-Key: <requestID>:<answer kind>` so a retried action is a
  replay, and a second action of another kind is 409.
- **Lists** carry `seq`: the event sequence number the list reflects. Lists are small and
  unpaginated. A list refreshes its slice of the client's state; it never moves the client's
  global `seq` (see State rules).
- **Rate limit.** Per device 20 requests a second, burst 60, and 30 answers and replies a minute;
  unauthenticated traffic (hello, pair, failed auth) 10 a minute, burst 5, for the whole Mac;
  pairing 5 attempts per code. Mac-server lists the buckets.

### Endpoints

Core endpoints. The "Only in Side A" endpoints are in [their own section](#only-in-side-a-endpoints).

| Method and path | Body | 2xx response | Errors |
|---|---|---|---|
| `GET /v1/hello` | | 200 `Hello` | |
| `POST /v1/pair` | `PairRequest` | 202 `PairPending` | 401 `bad_code`, 404 `no_pairing`, 409 `code_busy`, 410 `code_expired`, 429 |
| `POST /v1/pair/{attemptID}/wait` | | 201 `PairResponse` | 403 `declined`, 403 `sas_mismatch`, 404, 408 `confirm_timeout`, 410 `code_expired` |
| `DELETE /v1/pair/{attemptID}` | | 204 | |
| `DELETE /v1/devices/self` | | 204 | |
| `POST /v1/devices/push` | `PushRegistration` | 204 | |
| `POST /v1/devices/rekey` | `{devicePublicKey}`, signed (`ConfirmAction.rekey`, unlock) | 200 `{macPublicKey, keyID}` | 401 (no signature), 503 (no relay install) |
| `GET /v1/state` | | 200 `StateSnapshot` | |
| `GET /v1/setup` | | 200 `SetupStatus` (capability `setup`) | |
| `POST /v1/diagnostics/push` | | 200 `{id, relay: ok \| gone \| retry \| rejected \| unreachable}` | 503 (no relay install) |
| `POST /v1/diagnostics/push/{id}/received` | | 204 | 404 |
| `GET /v1/options` | | 200 `{agents: [AgentOptions]}` | |
| `GET /v1/sessions` | | 200 `{sessions: [RemoteSession], finished: [FinishedSession], seq}` | |
| `GET /v1/sessions/{id}` | | 200 `RemoteSession` | 404 |
| `GET /v1/sessions/{id}/transcript` | `?before=&after=&limit=&agent=` (`agent` = a subagent's `agentID`; also on `messages/{seq}`) | 200 `TranscriptPage` | 404 |
| `GET /v1/sessions/{id}/messages/{seq}` | `?generation=` | 200 `TranscriptMessage` uncut | 404, 410 |
| `POST /v1/sessions/{id}/reply` | `RemoteReply` | 200 `ReplyResult` | 404, 409, 422 |
| `POST /v1/sessions/{id}/interrupt` | `InterruptRequest` (optional) | 200 `InterruptResult` | 404, 409 `cannot_deliver` |
| `DELETE /v1/sessions/{id}/mail` | | 204 | 404 |
| `POST /v1/sessions/{id}/continue` | | 200 `HostedSession` | 409 `cannot_deliver` (working or unknown); 502 `not_resumed` `{hosted, command, hint}` (agent not back within 20 s) |
| `GET /v1/requests` | | 200 `{requests: [RemoteRequest], seq}` | |
| `GET /v1/requests/{rid}` | | 200 `RemoteRequest` uncut | 404 (also once resolved) |
| `POST /v1/requests/{rid}/answer` | `{answer: RemoteAnswer, mode?: PermissionMode}` (`mode` only with `.allow`, on a request listing `.allowMode`, one of its `modes`) | 200 `RequestResolution` | 404, 409 `already_resolved`, 422 (`not_allowed` for a mode the request doesn't list) |
| `GET /v1/images/{sha1}` | | 200 bytes | 404 |
| `GET /v1/images/{sha1}/thumb` | | 200 `image/jpeg`, 640 px on the long side | 404 |
| `POST /v1/uploads` | raw bytes, `Content-Type: image/*` | 201 `Upload` | 413, 415 |
| `GET /v1/projects` | | 200 `{projects: [RemoteProject]}` | |
| `GET /v1/hosted` | | 200 `{hosted: [HostedSession], seq}` | 503 `tmux_missing` |
| `POST /v1/hosted` | `StartHosted` | 201 `HostedSession` | 404 (no such folder), 409 `cannot_deliver` (`details.hint = "alreadyLive"`), 503 |
| `DELETE /v1/hosted/{name}` | | 204 | 404 |
| `POST /v1/hosted/{name}/trust` | | 200 `HostedSession` (capability `hosted.trust`) | 401 `confirm_required` / `confirm_invalid` (`details.level = biometric`), 404, 409 `cannot_deliver` (no trust dialog showing) |
| `GET /v1/accounts` | | 200 `{accounts: [RemoteAccount], seq}` | |
| `GET /v1/search` | `?q=&cursor=&limit=` | 200 `{results: [PastSession], next: Cursor?}` | |

```swift
public struct StateSnapshot: Codable, Hashable, Sendable {
    public let seq: Int
    public let epoch: String
    public let sessions: [RemoteSession]
    public let finished: [FinishedSession]
    public let requests: [RemoteRequest]
    public let hosted: [HostedSession]
    public let accounts: [RemoteAccount]
    public let mac: MacState?                // M3, capability "mac"
    public let incidents: [Incident]?        // M4, capability "incidents"
}

public struct SetupStatus: Codable, Hashable, Sendable {   // capability "setup"
    public let claudeHooks: Bool
    public let codexHooks: String            // "off", "unconfirmed", "trusted", "notInstalled"
    public let codexLastHeardAt: Timestamp?
    public let tmux: String                  // "ok", "missing", "tooOld"
    public let keepAwake: Bool
    public let onPower: Bool?
    public let relay: String                 // "ok", "unreachable", "unregistered"
    public let push: PushStatus              // for the calling device
    public struct PushStatus: Codable, Hashable, Sendable {
        public let registered: Bool
        public let lastResult: String?       // "ok", "gone", "retry", "rejected"
    }
}

public struct AgentOptions: Codable, Hashable, Sendable {   // capability "options"
    public struct Option: Codable, Hashable, Sendable { public let id: String; public let label: String }
    public let agent: AgentProvider
    public let installed: Bool
    public let models: [Option]              // what Side A's model menu offers for this agent
    public let efforts: [Option]             // low, medium, high, max (Claude); Codex reasoning efforts
    public let commands: [Option]            // slash commands, including the user's custom ones
}
```

Notes per endpoint:

- **`/hello`** needs no token (pairing and "is the Mac there" use it). With a valid token `paired`
  is true and the answer is whole. With a token the Mac doesn't know, `paired` is false and with no
  token it's absent; either way the name, id, addresses and key stay out. With a token while the
  device list can't be read, it answers 503 `not_ready`, as every authenticated route then does.
- **`/hello`** answers whenever Remote is on, even with nothing paired and no sheet open, so the
  phone can tell "Side A is closed" (connection refused) from "Remote is on, click Pair iPhone".
- **`/pair`** is described under Pairing. The routes answer 404 `no_pairing` while no pairing
  sheet is open on the Mac, so there is nothing to guess.
- **`/setup`** tells the phone the Mac's setup state for its one-time rows and Test Connection
  (setup, After pairing and Diagnostics). `push` describes the calling device only.
- **`/diagnostics/push`** sends one push of category `TEST` (no actions, collapsed by its id) to
  the calling device through the relay and returns the relay's result; the phone confirms receipt
  with `…/received` from the Service Extension or `willPresent`. The Mac's per-phone Send Test
  Notification uses the same path internally.
- **Transcript paging.** No cursor: the newest `limit` messages. `before=c`: messages with seq
  below `c`, newest first then returned ascending. `after=c`: messages above `c`, ascending, plus
  `replaced`. `limit` defaults to 50, at most 200. Both cursors together is 400. A cursor from
  another generation answers 200 with `reset: true` and the newest page. Pages are read through
  the bridge's `show --format remote`.
- **Message by seq, not uuid.** The plan said `/messages/{uuid}`; a uuid can map to several
  messages, so the path takes `seq` and requires the `generation`.
- **Images.** `ETag` is the id and `Cache-Control: private, max-age=31536000, immutable`;
  `If-None-Match` gets 304. The server serves only ids in its `images` table. Thumbnails are made
  once into `runtime/thumbs/<sha1>.jpg`.
- **Answer.** Checked in this order: request exists (404), still open (409 with the resolution),
  then the refusals of the RemoteAnswer table. With `confirm.signed`, the server checks the
  `X-SideA-Confirm` signature against the device's confirm or unlock key, so a stolen token can't
  approve a gated request without the phone's Secure Enclave and, for `.biometric`, its owner's
  face. Success is
  answered the same way the island does (`Island.answer(_, id)`), and `request.resolve` goes to
  every client.
- **Reply** with `.typed` delivery is the paste-buffer, Enter and verifier sequence in
  [hosting](hosting.md#reply-text). The response returns once the text is in the pane, not once
  the agent read it.
- **Interrupt.** `when: now` (default): hosted sends Esc (only while working, else 409);
  unhosted Claude while working leaves stop mail; otherwise 409. `when: nextStep` (capability
  `interrupt.nextStep`): leaves stop mail, hosted or not, Claude only.
- **Continue on phone** ends the Mac process and resumes the conversation in tmux. Only while
  `status` is idle, waiting or finished; working and unknown are 409.
- **`POST /v1/hosted`** is idempotent through the persisted `Idempotency-Key` record (a retried
  start never makes two sessions; a start interrupted by a Mac crash is `outcome_unknown`, and the
  phone checks `GET /v1/hosted` before offering Retry). 201 returns as soon as tmux has the
  session; the `RemoteSession` follows by event. A `resume` of a conversation that is already
  live is 409 `alreadyLive` (hosted: the phone opens it instead).
- **Uploads** are stored by the Mac (hosting, Images: downscaled, EXIF dropped) under
  `runtime/uploads/` (0600) and deleted after 7 days. MIME is sniffed from the bytes (HEIC, JPEG,
  PNG, GIF, WebP), not trusted from the header. The response is always an `Upload`; replies and
  `StartHosted` refer to it by `id`, and the Mac resolves ids to paths.
- **`/options`** lists what the composer's Model, Effort and Commands rows offer, per agent, so
  the phone never hard-codes a model list.

### Only in Side A endpoints

Every feature in the plan's "Only in Side A" list, and every row of ios-app's former 4.15 table,
has a contract here (built by the protocol lane; these shapes are canonical). Each is gated by its
capability: a Mac without it doesn't list it in `Hello`, and the phone hides the feature with
"Update Side A on your Mac to …". All mutations follow the rules above (persisted idempotency, the
error envelope, per-device rate limits); all need a paired device token, and nothing here bypasses
`abilities`. The server accepts GET, POST and DELETE only, so changes are POST.

Using an account and switching Autopilot act Mac-wide, so only the confirm key signs them (Autopilot
off too), and the phone never offers them from the Lock Screen, a notification action or a widget. A Claude
account is used through the shell line that shell switching installs, and turning Autopilot on
would turn shell switching on. Only the Mac does that, because it edits the shell's startup file.
While it's off, both refusals come before the confirm with `details.hint = shellSwitching` and the
message "Turn on shell switching in Side A on your Mac first.", so the phone shows that instead of
asking for Face ID. Turning Autopilot off needs no shell switching but is still signed.

**Rotation** (`rotation`). `GET /v1/autopilot` and the snapshot add, all optional: `held` (every move
Autopilot holds, oldest first; `pending` is the first, which Move Now runs), `next` (per login in use,
`NextMove`: where its sessions go at `atPercent`, with `minutes` an estimate at the recent 5-hour
pace, rounded to five minutes, nil when the pace says nothing or the window resets first), `waiting`
(`WaitingSummary`: the first account back for sessions stopped on a limit), `swapAt`, `followFable`
and `fableMode`. `AutopilotDecision` adds the kinds `stuck` and `priorityWait`, and `recacheTokens` on
a held move when Live Limits gives it; moves come from structured records in `runtime/rotation.json`
with `reason` ("5-hour 96%") and `sessions`, while older log lines stay with an empty `reason`.

`RemoteAccount` adds `priority`, `allowAuto`, `limited`, `fableOut`, `backAt` and `issue`. `limited` is
the Mac's Planner: a running 5-hour or weekly window at or past both the Move at setting and 97%. A cap
on one model is never `limited`; `fableOut` says the account has room but none for Fable. A phone
without them, or a Mac without `rotation`, reads the percentages as before. `RemoteSession.limit` marks
a session whose own last reply was a limit error, while that limit holds; `until` is the window's
reset, and `worstCase` says the reply gave it only in words, so it is the longest it could take.

`UsageOutlook.Room.runsOut` is a new calculation, not a reading. Each account's pace is what it used
over the share of its week gone by, at the user's weekly rhythm, counting at least a quarter of a
week so a burst on a new week isn't taken for its whole pace. The hours ahead spend that pace,
soonest-reset account first, while resets refill their accounts. It is nil if that doesn't empty them
within a week, and nil rather than a guess without a rhythm (a week of activity; Codex has none), with
an account unread, stale or failing, read over an hour ago, or with under a day of any week to read.

Answering with the recommended choice (`autopilot.answers`) is signed the same way, and needs no
shell switching. While it's on, a request the Mac holds that is a plan (`ExitPlanMode`), or a
question whose every question has an option marked "(Recommended)", is answered by the Mac after 60
seconds unanswered: the plan is approved with edits still asked for (`acceptEdits: false`), and each
question gets its recommended options (all of them on a multi-select). A question with no marked
option waits; no form starts on the first option. Permission requests are never answered this way.
The timer runs on the Mac, so it works with the phone asleep; an answer from anywhere first cancels
it, and turning the setting on gives requests already waiting their minute from then. The answer is
`request.resolve` with `by: autoAnswered` (and its `answer` kind), in the approvals log, and an
`AutopilotDecision` of kind `answered` (`title` "Answered for you in <session>", `reason` the
answer).

| Feature | Milestone | Capability | Method and path | Body | 2xx | Errors |
|---|---|---|---|---|---|---|
| Notes, Take Back, Interrupt | M1 | `reply.note`, `interrupt` | `reply` with `mode: note`; `DELETE …/mail`; `POST …/interrupt` | | as above | as above |
| Stop Before Next Step | M1 | `interrupt.nextStep` | `POST /v1/sessions/{id}/interrupt` | optional `{when: "now" \| "nextStep"}` | 200 `InterruptResult` | 409 `cannot_deliver` |
| Health flags on rows | M1 | (core) | `RemoteSession.flag` | | | |
| Model and effort options | M1 | `options` | `GET /v1/options` | | `{agents: [AgentOptions]}` | |
| Session settings | M5 | `settings` | `POST /v1/sessions/{id}/settings` | `SettingsChange {model?, effort?, mode?, fast?}` + `X-SideA-Confirm` (`settings`) | 200 `SettingsResult {settings, nextTurn}` | 401 `confirm_required` / `confirm_invalid`, 404, 409 `cannot_deliver` (the session can't take it now; the message says why), 422 (a field its `settings.*` ability lacks, an effort the model doesn't take) |
| Models for settings | M5 | `settings` | `GET /v1/models?kind=claude\|codex[&session=]` (`session` picks that Codex session's home) | | 200 `ModelList {agent, models: [ModelOption]}` (`ModelOption.isDefault`, `.fast`) | 404 (unknown session) |
| Launch mode | M5 | `settings` | `POST /v1/hosted` with `StartHosted.permissionMode` (`--permission-mode`, Codex `-a`/`-s`) | | as above | 401 when it raises without a confirm-key `settings` signature |
| Allow and switch mode | M5 | `answers.mode` | `POST /v1/requests/{rid}/answer` with `mode` (Claude `updatedPermissions setMode`, destination session) | | as above | as above |
| What changed this turn | M5 | `turns.diff` | `GET /v1/sessions/{id}/turns/{turnID}/diff` | | 200 `TurnDiff {sessionID, turnID, files: [FileDiff], running}` | 404 |
| Plan list, background tasks | M5 | (core) | `RemoteSession.plan`, `.backgroundTasks` | | | |
| Compact, Review | M5 | (abilities) | `POST /v1/sessions/{id}/compact`; `POST /v1/sessions/{id}/review` `{target: "uncommittedChanges"}` | | 204 | 404, 409 `cannot_deliver` (not idle) |
| Search | M3 | `search` | `GET /v1/search` | | as above | |
| History browse | M3 | `history` | `GET /v1/history?archived=&project=&cursor=` | | 200 `HistoryPage` | |
| Pin, rename, archive | M3 | `history` | `POST /v1/history/{id}` | `HistoryChange` | 200 `PastSession` | 404 |
| Past conversation transcript | M3 | `history` | `GET /v1/sessions/{conversationID}/transcript`, the same route, for any indexed conversation, live or not | | `TranscriptPage` | 404 |
| Resume, Fork hosted | M3 | `hosted` | `POST /v1/hosted` with `resume`, `fork` | | `HostedSession` | 409 `alreadyLive` |
| Restart Fresh: draft | M3 | `restart` | `POST /v1/sessions/{id}/handoff` | | 200 `Handoff` (a draft; changes nothing) | 404 |
| Restart Fresh: run | M3 | `restart` | `POST /v1/sessions/{id}/restart` | `{handoff: Handoff, accountID?, model?}` | 201 `HostedSession`; idempotent | 404, 409 |
| Ports and memory per session | M3 | `ports` | `RemoteSession.ports`, `.memoryBytes` | | | |
| Stop Server | M3 | `ports` | `POST /v1/sessions/{id}/ports/{port}/stop` | | 204 | 404 `port_not_found` |
| Preview a dev server | M3 | `ports` | `POST` / `DELETE /v1/sessions/{id}/ports/{port}/preview` | | 200 `{url}` / 204 | 404 `port_not_found` |
| Quit Session (any session) | M3 | `quit` | `POST /v1/sessions/{id}/quit` | | 204 | 404, 409 `cannot_deliver` (headless or Side A's own priming) |
| Quit Idle | M3 | `quit` | `POST /v1/sessions/quit-idle` | `{olderThanMinutes: Int}` | 200 `{quit: [SessionKey]}` | |
| The Mac's state | M3 | `mac` | `StateSnapshot.mac`, event `mac.update` | | | |
| Keep awake | M3 | `mac` | `POST /v1/mac/settings` | `{keepAwake?: Bool}` | 200 `MacState` | |
| Autopilot decisions | M4 | `autopilot` | `GET /v1/autopilot` | | 200 `AutopilotState` | |
| Move Now | M4 | `autopilot` | `POST /v1/autopilot/move` | | 200 `AutopilotState` | 409 `nothing_to_move` |
| Answer with recommended after 1 minute | M5 | `autopilot.answers` | `POST /v1/autopilot/answers` | `AutopilotChange {enabled: Bool}` + `X-SideA-Confirm` (`autopilot`, confirm key) | 200 `AutopilotState` | 400 `bad_request`; 401 `confirm_required` / `confirm_invalid` (`details.level = biometric`) |
| Autopilot on or off | M5 | `autopilot.toggle` | `POST /v1/autopilot` | `AutopilotChange {enabled: Bool}` + `X-SideA-Confirm` (`autopilot`, confirm key) | 200 `AutopilotState` | 400 `bad_request`; turning it on: 409 `cannot_deliver` `details.hint = shellSwitching` (shell switching is off on the Mac), checked before the confirm; then 401 `confirm_required` / `confirm_invalid` (`details.level = biometric`) |
| Use an account | M5 | `accounts.use` | `POST /v1/accounts/{id}/use` | `{}` + `X-SideA-Confirm` (`account`, confirm key) | 200 `{accounts: [RemoteAccount], seq}`, the account `active` for its provider | Checked before the confirm: 404 `not_found`, 409 `account_not_ready`, and for a Claude account 409 `cannot_deliver` `details.hint = shellSwitching`; then 401 `confirm_required` / `confirm_invalid` (`details.level = biometric`); 502 `cannot_deliver` when the switch itself fails |
| Combined room | M6 | `rotation` | `GET /v1/usage/outlook` | | 200 `UsageOutlook` | |
| An account's priority | M6 | `rotation` | `POST /v1/accounts/{id}/priority` | `PriorityChange {priority}` + `X-SideA-Confirm` (`rotation`, confirm key) | 200 `{accounts: [RemoteAccount], seq}` | 400 `bad_request`, 404 `not_found`, both before the confirm; then 401 `confirm_required` / `confirm_invalid` (`details.level = biometric`) |
| An account's Auto | M6 | `rotation` | `POST /v1/accounts/{id}/auto` | `AutopilotChange {enabled}` + `X-SideA-Confirm` (`rotation`, confirm key) | 200 `{accounts: [RemoteAccount], seq}` | as above |
| Move at | M6 | `rotation` | `POST /v1/rotation/swap-at` | `SwapAtChange {percent}`, one of 80, 85, 90, 95, 97, 99, + `X-SideA-Confirm` (`rotation`, confirm key) | 200 `AutopilotState` | 400 `bad_request` before the confirm; then 401 as above |
| Follow Fable | M6 | `rotation` | `POST /v1/rotation/follow-fable` | `AutopilotChange {enabled}` + `X-SideA-Confirm` (`rotation`, confirm key) | 200 `AutopilotState` | as above |
| Pool mode | | `rotation` | `POST /v1/rotation/pool` | anything | | always 409 `cannot_deliver` `details.hint = poolOnMac`: pool mode changes only on the Mac, signed or not |
| Autopilot's state, live | M6 | `rotation` | `StateSnapshot.autopilot`, event `autopilot.update` (the whole `AutopilotState`, when it changed, at most one a second) | | | |
| Rotation push | M6 | `rotation` | push category `ROTATION` (Push payloads), to a phone whose latest `hello` lists `rotation` and whose `prefs.rotation` is true | | | |
| Worth at API prices | M4 | `worth` | `MacState.worth` (in StateSnapshot.mac and event mac.update) | | | |
| Claude incidents | M4 | `incidents` | `StateSnapshot.incidents`, event `incident.update` (the full open list; `[]` clears it) | | | |
| Clean Up | M4 | `cleanup` | `GET /v1/cleanup`; `POST /v1/cleanup/archive` `{olderThanDays}`; `POST /v1/cleanup/restore`; `DELETE /v1/worktrees/{id}` | | 200 `CleanupReport`; restore 200 `{count}`; delete 204 | 409 `worktree_kept` |
| Health push | M2 | `push` | push category `HEALTH` (Push payloads), once per session per hour when a flag starts | | | |
| Update Side A | M4 | `update.check` | `POST /v1/update/check` (Sparkle's check) | | 202 | |
| Remote approvals log | M4 | `history` | `GET /v1/approvals?cursor=` | | `ApprovalsPage {approvals: [{resolution: RequestResolution, request: RequestSummary}], next}` | |

```swift
public struct ListeningPort: Codable, Hashable, Sendable {   // RemoteSession.ports
    public let port: Int
    public let process: String                // "node", "vite"
    public let previewURL: String?            // set while a preview is up
}

public struct HistoryPage: Codable, Hashable, Sendable { public let sessions: [PastSession]; public let next: Cursor? }
public struct HistoryChange: Codable, Hashable, Sendable {
    public let pinned: Bool?, title: String?, archived: Bool?   // title "" clears the custom title
}

public struct Handoff: Codable, Hashable, Sendable {
    public var goal: String, branch: String?, failed: String, next: String, lastMessages: String
    public let cwd: String, project: String
    public var accountID: String?, model: String?
}

public struct MacState: Codable, Hashable, Sendable {
    public struct Pressure: OpenEnum { public let rawValue: String }   // .normal, .warning, .critical
    public let onPower: Bool
    public let battery: Int?                  // percent
    public let memoryUsed: Int, memoryTotal: Int    // bytes
    public let memoryPressure: Pressure
    public let sessionMemory: Int             // bytes held by agent sessions
    public let keepAwake: Bool
    public let worth: Worth?                  // Mac-wide, at API prices; the usage report has no per-account split
}

public struct AutopilotState: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let pending: AutopilotDecision?    // a move Autopilot is holding (Move Now applies it)
    public let decisions: [AutopilotDecision] // newest first
    public let answersRecommended: Bool?      // answering with the recommended choice; nil without autopilot.answers
}
public struct AutopilotDecision: Codable, Hashable, Sendable {
    public struct Kind: OpenEnum { public let rawValue: String }   // .moved, .waiting, .failed, .primed, .answered
    public struct Moved: Codable, Hashable, Sendable { public let sessionID: SessionKey; public let title: String }
    public let id: String, at: Timestamp, kind: Kind, title: String, reason: String
    public let from: String?, to: String?     // account names
    public let sessions: [Moved]
}

public struct Worth: Codable, Hashable, Sendable { public let days7: Double, days30: Double, currency: String }   // MacState.worth
public struct ApprovalsPage: Codable, Hashable, Sendable {
    public struct Approval: Codable, Hashable, Sendable { public let resolution: RequestResolution; public let request: RequestSummary }
    public let approvals: [Approval]
    public let next: Cursor?
}
public struct RequestSummary: Codable, Hashable, Sendable {   // what was asked, kept after the request resolved
    public let tool: String                  // "Bash", "Edit", "AskUserQuestion", Codex "exec", an MCP tool's name
    public let headline: String              // RemoteRequest.headline as it was
    public let sessionTitle: String?
    public let agent: AgentProvider
}

public struct Incident: Codable, Hashable, Sendable {
    public let id: String, provider: AgentProvider, title: String, status: String, url: String
    public let startedAt: Timestamp?
}

public struct CleanupReport: Codable, Hashable, Sendable {
    public struct Archivable: Codable, Hashable, Sendable { public let olderThanDays: Int, count: Int, bytes: Int }
    public struct LeftWorktree: Codable, Hashable, Sendable {
        public struct Keep: OpenEnum { public let rawValue: String }   // .changes, .inUse, .noBranch, .ignoredFiles
        public let id: String, path: String, branch: String?, bytes: Int?
        public let keep: Keep?                // nil: removable
        public let keepReason: String?
    }
    public let conversationBytes: Int, conversations: Int
    public let archivable: [Archivable]
    public let archived: Int
    public let worktrees: [LeftWorktree]
}
```

`PastSession` gains `parentID: String?`, `pinned: Bool?`, `archived: Bool?`, `customTitle: String?`
(M3, `history`). `MacState` gains `worth: Worth?` (M4), Mac-wide. Pins, titles and archives stay in
Side A; nothing touches Claude's or Codex's files.

- **Restart Fresh** ends the old session (SIGTERM, as Quit) only after the new hosted session has
  started.
- **Preview.** The returned `url` must be served by Side A's own pinned listener (a proxy at
  `/v1/preview/{port}/…` on the same port), with the WebView's navigation delegate pinning the
  Mac's key and a short-lived preview credential in the URL or a cookie. It must not be a
  Tailscale Serve path: Remote doesn't use Serve, and a Serve path would expose the dev server to
  the whole tailnet. `DELETE` takes it down; it also goes after 30 minutes and when the session
  ends.

## WebSocket: /v1/ws/events

### Framing

Text frames, one JSON object each, at most 1 MiB (see Size bounds for how transcript events
stay under it). The upgrade (`GET /v1/ws/events` with `Upgrade: websocket` on the same TLS port as REST)
carries the same `Authorization` and `X-SideA-Protocol` headers; Host, Origin and the token are
checked before `101 Switching Protocols`. Server events:

```swift
public struct EventEnvelope: Codable, Sendable {
    public let seq: Int?             // state events only; transcript and control events have none
    public let at: Timestamp
    public let event: ServerEvent    // flattened: {"seq": 41, "at": …, "type": "session.upsert", "data": {…}}
}

public enum ServerEvent: Codable, Sendable {
    // control
    case welcome(Welcome)                        // "welcome"
    case snapshot(StateSnapshot)                 // "snapshot"
    case bye(reason: String)                     // "bye": quit, update, sleep
    // state (sequenced)
    case sessionUpsert(RemoteSession)            // "session.upsert"
    case sessionRemove(id: SessionKey, replacedBy: SessionKey?)            // "session.remove"
    case requestAdd(RemoteRequest)               // "request.add"
    case requestResolve(RequestResolution)       // "request.resolve"
    case finishedAdd(FinishedSession)            // "finished.add"
    case finishedResolve(sessionID: SessionKey, reason: String)            // "finished.resolve": replied, resumed, released, expired
    case usageUpdate([RemoteAccount])            // "usage.update": only the accounts that changed
    case accountRemove(id: String)               // "account.remove": {"id": …}, removed from the Mac's library
    case hostedUpsert(HostedSession)             // "hosted.upsert"
    case hostedRemove(name: String)              // "hosted.remove"
    case hostedAttention(HostedAttention)        // "hosted.attention": trust dialog, stuck screen, unsent prompt (hosting)
    case macUpdate(MacState)                     // "mac.update" (M3)
    case incidentUpdate([Incident])              // "incident.update" (M4)
    case autopilotUpdate(AutopilotState)         // "autopilot.update" (M6); an older phone decodes it as .unknown
    // transcript (per subscription, unsequenced)
    case transcriptAppend(TranscriptDelta)       // "transcript.append"
    case transcriptReplace(TranscriptDelta)      // "transcript.replace"
    case transcriptReset(sessionID: SessionKey, generation: String)        // "transcript.reset"
    case unknown(type: String)                   // decoded, ignored
}

public struct Welcome: Codable, Sendable {
    public let epoch: String
    public let seq: Int                  // the server's current seq
    public let replay: Bool              // true: events lastSeq+1…seq follow; false: a snapshot follows
    public let snapshotOverREST: Bool    // replay false and the snapshot is over 512 KiB: GET /v1/state instead
    public let hello: Hello
}

public struct TranscriptDelta: Codable, Sendable {
    public let sessionID: SessionKey
    public let generation: String
    public let messages: [TranscriptMessage]   // ascending seq
    public let cursor: Cursor                  // the new `after` cursor, covering these rows and revisions
}
```

Client messages:

```swift
public enum ClientMessage: Codable, Sendable {
    case hello(epoch: String?, lastSeq: Int?, capabilities: Set<Capability>)   // "hello"
    case subscribe(sessions: [SessionKey: Cursor?])  // "subscribe": session → the latest `after` cursor held (nil: none)
    case unsubscribe(sessions: [SessionKey])     // "unsubscribe"
    case presence(foreground: Bool, viewing: SessionKey?)                      // "presence"
}
```

Like every tagged union here, a client message is `{"type": "subscribe", "data": {"sessions": {…}}}`.

### Connect, replay, snapshot

1. Client opens the socket and sends `hello` within 5 seconds (else close 4400).
2. The server keeps a ring of the last 500 state events or 10 minutes, whichever is fewer.
   - Same `epoch` and `lastSeq` still in the ring: `welcome{replay: true}`, then every event after
     `lastSeq`, in order.
   - Otherwise (first connect, other epoch after a relaunch, too old): `welcome{replay: false}`,
     then one `snapshot` whose `seq` is the starting point. If the snapshot would be over
     512 KiB, `welcome{snapshotOverREST: true}` and the client fetches `GET /v1/state` (which
     answers at the same `seq`, held for 30 s) before applying live events.
3. Live events follow, `seq` exactly one more than the last. A client that sees a jump closes the
   socket and reconnects with its `lastSeq`, which repairs from the ring or a snapshot.
4. The client re-sends `subscribe` and `presence` after every `welcome`.

`seq` resets to 0 on each launch together with a new `epoch`; a client compares the pair, never
`seq` alone.

### Transcript subscriptions

- `subscribe{sessions: {key: cursor}}` adds sessions; at most 8 per connection (the oldest
  falls off). The cursor is the latest `after` the client holds for that session (from a page or
  a delta), unchanged. On subscribe the server compares it with the session's current state: if
  the generation is current and at most 200 rows are new or revised since it, it sends
  `transcript.append` with the new rows and `transcript.replace` with the revised older ones,
  each carrying the new cursor; otherwise `transcript.reset`, and the client fetches pages.
  `nil` means "nothing held": the server sends nothing until new rows arrive.
- New messages come as `transcript.append`, merged over 60 ms per session. A message that grew
  (a tool result arrived, another tool call folded into the same row) comes as `transcript.replace`
  with its `seq`. A rebuilt view is `transcript.reset`. Every delta carries the cursor that covers
  it, which the client stores as its new `after`.
- Transcript events are not in the ring: the paged fetch is the truth, and `seq` within the
  delta is the gap check (see Sync).

### Presence and lease

- `presence` is sent on connect, on every foreground or background change, on every change of the
  open session, and every 30 seconds as a lease. The server forgets a device's presence 45 seconds
  after its last `presence` or when its socket closes.
- While a device is foreground and `viewing` a session, the Mac sends no push for that session to
  that device.

### Keepalive and backpressure

- The client sends WebSocket pings every 15 seconds (`sendPing`); the server closes a socket
  silent for 45 seconds. The server pings too, with the same timeout.
- Each connection has an outbound queue of at most 1 MiB. `usage.update` is coalesced to one per
  5 seconds, `session.upsert` per session to one per 250 ms (latest wins), transcript deltas per
  60 ms. `account.remove` goes out with the same coalesced `usage.update` pass; a phone from before it
  reads it as `.unknown`, moves its `seq` on, and drops the row at its next snapshot or
  `GET /v1/accounts`. If the queue still overflows, the server drops it and closes with 4008; the client
  reconnects with its `lastSeq`.

### Close codes

| Code | Meaning | Client does |
|---|---|---|
| 1000 | normal | nothing |
| 1001 | server going away (`bye` sent first) | reconnect with backoff |
| 4008 | too slow, queue dropped | reconnect at once with `lastSeq` |
| 4400 | no or bad `hello` | report a bug, reconnect |
| 4401 | unauthorized or revoked | stop, show "Pair again" |
| 4426 | protocol unsupported | stop, show which side to update |
| 4429 | too many connections (4 per device) | reconnect after 10 s |
| 4500 | internal error | reconnect with backoff |

Backoff: 0.5 s doubling to 30 s, with ±20 % jitter; reset after 60 s connected. Immediate retry on
network path change and app foreground.

## WebSocket: /v1/ws/term/{name}

One socket per terminal view of a hosted session. This is the only definition of the terminal
wire format; [hosting](hosting.md#terminal-streaming) implements the Mac end and refers here. The
server attaches a new tmux client in a PTY it owns (`tmux -L sidea attach -f ignore-size -t
=<name>`); tmux repaints the whole screen on attach, so output is never replayed across
reconnects, only input is. Fixtures: `TermControl.*.json` for each case, and
`TermFrame.output.bin` / `TermFrame.input.bin` for the binary layouts.

### Frames

Text frames carry control JSON (`{"type", "data"}`, as everywhere); binary frames carry bytes.

| Direction | Binary layout |
|---|---|
| server → client, output | `0x01` then raw PTY bytes, coalesced about 4 ms, ≤ 32 KiB per frame |
| client → server, input | `0x02`, u32 big-endian `seq`, then bytes, ≤ 16 KiB per frame |

```swift
public enum TermControl: Codable, Sendable {
    // client → server
    case hello(viewer: String, cols: Int, rows: Int)         // "hello": viewer is a UUID per (device, terminal view), kept across reconnects
    case resize(cols: Int, rows: Int)                        // "resize"
    // server → client
    case ready(epoch: String, applied: UInt32?, cols: Int, rows: Int, owner: String)
                                                             // "ready": applied = last input seq written for this viewer in
                                                             //  this epoch; nil when the server has no record of the viewer
    case ack(seq: UInt32, error: String?)                    // "ack": every input up to seq is in the PTY; error "too_large"
    case size(cols: Int, rows: Int, owner: String)           // "size": the size to render at; owner "mac" or "phone"
    case mode(copy: Bool)                                    // "mode": the Mac is in tmux copy mode (hosting, caveats)
    case exit(status: Int?, reason: String)                  // "exit": ended, killed; then close 4410
}
```

### Input, numbered and acked (from Codeman)

- Input seq starts at 1 per viewer and counts frames. The client persists unacked frames in the
  App Group outbox store, up to 256 KiB; past that it stops accepting keys and shows
  "Reconnecting".
- The server writes frames in order (one `write` per frame, so a key sequence never splits), acks
  at most every 50 ms (and after any frame that drains its queue), and remembers `applied` per
  viewer for 120 seconds after the socket closes, in memory.
- **Reconnect, same epoch, viewer known:** `hello{viewer}`, `ready{epoch, applied}`; the client
  drops frames ≤ `applied` and resends the rest at once. A frame with `seq ≤ applied` is dropped
  and acked again; one with `seq > applied + 1` closes the socket with 4422.
- **Uncertain delivery.** When `ready.epoch` differs from the epoch the frames were sent under
  (Side A restarted), or `ready.applied` is nil (the 120-second record expired), the client can't
  know which frames reached tmux, and a frame that carried Enter may already have run. It
  **discards every unacked frame**, never replays them, and shows a notice in the terminal view:
  "Side A restarted. Some keys may not have reached the session." Seq then starts again at 1.
  Freshness is never used to guess. Chat replies go through REST with persisted idempotency and
  aren't affected.
- A frame over 16 KiB is refused with `ack{seq, error: "too_large"}`. Pastes larger than 16 KiB
  are split by the client into consecutive frames, never inside a UTF-8 sequence. Predictive echo
  is client only and never changes what is sent.

### Size

`resize` asks; the server decides (Decision 5, hosting's Resize): the Mac's own client wins while
it typed in the last minute, otherwise the most recent phone size applies. Every change of the
effective size is a `size` message; the client lays out to it and letterboxes or scales if its
view is larger.

### Backpressure and keepalive

When more than 1 MiB waits on the socket, the server stops reading the PTY; tmux drops what the
slow client can't take and redraws when it catches up. Keepalive as for events.

### Close codes

| Code | Meaning |
|---|---|
| 1000 | client closed |
| 1001 | server going away |
| 4401 | unauthorized or revoked |
| 4404 | no hosted session by that name |
| 4409 | more than 4 viewers on this session (the oldest is closed with it) |
| 4410 | session ended (`exit` sent first) |
| 4422 | input sequence gap |
| 4426 | protocol unsupported |

## Push payloads

What the Mac puts inside a push and what the phone reads out of it. The relay's own API (signed
requests, `/v1/send`, limits) is in [relay-and-release](relay-and-release.md); the shapes the Mac
and the phone share through it are here. Fixtures: `PushPayload.*.json`, `ActivityContentState.*.json`
and `Envelope.*.bin` with a known key (v2 is current; the v1 vector stays to check that it's refused).

### APNs payload as delivered

```json
{ "aps": { "alert": { "loc-key": "PUSH_REQUEST_FALLBACK" }, "mutable-content": 1,
           "category": "REQUEST", "sound": "default", "interruption-level": "time-sensitive" },
  "e": "<base64url envelope for this device>" }
```

- The envelope key is `e`. The Mac's send carries `sealed` as a map, one envelope per destination
  device, `{"<deviceId>": "<envelope>", …}`, because the key and the AAD are per device; the relay
  puts each device's envelope under `e` in that device's push.
- **Envelope:** `base64url(0x02 ‖ keyId(4) ‖ nonce(12) ‖ ciphertext ‖ tag(16))`, ChaCha20-Poly1305
  with the per-device push key, `AAD = 0x02 ‖ keyId ‖ len‖category ‖ len‖collapseId ‖ len‖deviceId`
  (2-byte big-endian lengths; v1 retired, see relay-and-release).
- **Wire categories** (the relay's allowlist; each has a fixed `loc-key` shown if the Service
  Extension can't run):

| Category | `loc-key` | Payload `t` |
|---|---|---|
| `REQUEST` | `PUSH_REQUEST_FALLBACK` | `request` (gate `.lockScreen` or `.unlock`) |
| `REQUEST_DESTRUCTIVE` | `PUSH_REQUEST_FALLBACK` | `request` (gate `.biometric`) |
| `QUESTION` | `PUSH_QUESTION_FALLBACK` | `question` |
| `PLAN` | `PUSH_PLAN_FALLBACK` | `plan` |
| `FINISHED` | `PUSH_FINISHED_FALLBACK` | `finished` |
| `LIMIT` | `PUSH_LIMIT_FALLBACK` | `limit` |
| `HEALTH` | `PUSH_HEALTH_FALLBACK` | `health` (a flag started: `sid`, `title`, `body` = the flag's words) |
| `ROTATION` | `PUSH_ROTATION_FALLBACK` | `rotation` (`title` "Now on Personal", "All out", "Fable out" or "Work is full"; `body` a reason, or `account` and `resetsAt` for who is back. Account names and a limit's numbers only) |
| `TEST` | `PUSH_TEST_FALLBACK` | `test` (Test Connection; no actions) |
| `ANSWERED` (relay `kind: "dismiss"` only) | `PUSH_ANSWERED` | none: no envelope, replaces the collapse id |

- The phone registers local categories with the same names, plus two that never travel.
  `REQUEST_SAFE`: the Service Extension switches a `REQUEST` to it only when the decrypted,
  authenticated payload says `gate: "lockScreen"` (ios-app 5.1). `OPEN` (Open only, no Allow): any
  `REQUEST` or `REQUEST_DESTRUCTIVE` whose payload was cut to fit (`full: false`) becomes `OPEN`,
  whatever its gate, so nothing is allowed unseen. Decryption makes only those two changes, and
  `PushCategory.local(for:)` is the one place both are decided.

**Token verification push.** A new or changed APNs token starts unverified at the relay, which
sends it one silent push, `{"aps": {"content-available": 1}, "verify": {"install": "<installID>",
"device": "<deviceID>", "challenge": "<16 bytes base64url>"}}`. The app answers
`POST /v1/device/verify {challenge}` to the relay with its `d1.…` bearer. Until then a send to
that device returns `unverified` (relay-and-release, Endpoints).

### Sealed payload (plaintext before sealing, at most 2,048 bytes)

```swift
public struct PushPayload: Codable, Sendable {   // tagged by "t"
    public let v: Int                    // 1
    public let t: String                 // request, question, plan, finished, limit, health, test
    public let mac: String               // MacInfo.id
    public let sent: Timestamp
    // request
    public let rid: RequestID?, sid: SessionKey?
    public let title: String?            // "Allow Bash" (RemoteRequest.headline)
    public let subtitle: String?         // "side-a · Work"
    public let body: String?             // the command or detail, cut to fit
    public let gate: AllowGate?
    public let risk: IslandRisk?, riskReason: String?
    public let agent: AgentProvider?
    // question: every question with its options, or full == false
    public let questions: [IslandQuestion]?
    // plan: the plan's markdown, or full == false
    public let plan: String?
    public let full: Bool?               // false: content didn't fit; the extension offers Open only
    // finished
    public let turnID: String?, summary: String?
    // limit
    public let account: String?, window: String?, percent: Int?, resetsAt: Timestamp?
}
```

- **Budget.** The Mac fills a payload to at most 2,048 bytes before sealing (the relay caps the
  envelope at 3,000 characters and the APNs payload at 4 KB). A request's `body` is cut to fit. A
  question set or plan that doesn't fit whole is sent with `full: false` and without
  `questions`/`plan`: the notification says "Claude has a question · Open to answer", and the
  Content Extension shows Open instead of partial options, so nobody answers a question they
  couldn't see in full.
- `finished` carries `turnID`, which the Reply action sends back as `RemoteReply.turnID`.

### Live Activity content state

ActivityKit pushes skip the Service Extension, so `content-state` and the attributes reach Apple
and the relay in plaintext. They hold **counts, times and opaque ids only**:

```swift
struct MacActivityAttributes: ActivityAttributes {
    let macID: String                    // base64url(SHA-256("SideA macID v1\n" + installID)[0..<12]); never the Mac's name
    struct ContentState: Codable, Hashable {
        var working: Int
        var waiting: Int
        var topRequest: String?          // a random request id, or nil
        var soonestReset: Date?          // encoded as seconds since 2001 (ActivityKit's default Date decoding)
        var tightestPercent: Int?        // 0–100
    }
}
```

All words (session title, project, account, command) come from the phone's decrypted local cache
(the Service Extension writes each decrypted request, keyed by id, to `shared.sqlite`); when
`topRequest` isn't there, the activity says "1 needs you" and its buttons open the app. A
push-to-start carries `attributes: {macID}` and the generic alert iOS requires
(`ACTIVITY_START_TITLE`, `ACTIVITY_START_BODY` loc-keys).

## Versioning and compatibility

The Mac app (Sparkle) and the phone app (App Store) update on their own schedules, and the phone
may talk to several Macs of different versions. The rules:

1. **One major per path.** `/v1` changes only additively: new endpoints, new optional fields, new
   open-enum values, new event types, new action kinds (with `tool` and `arguments`). Renaming or
   removing a field, changing a type, or making an optional field required is `/v2`, served
   alongside `/v1` for at least six months.
2. **Decoders are lenient.** Unknown keys are ignored. Unknown open-enum values are kept. Unknown
   event types decode to `.unknown` and are dropped. Unknown `IslandAction` kinds become `.other`.
   An unknown `IslandRisk` is treated as destructive. A missing optional field means "this Mac
   doesn't know", never false.
3. **Capabilities, not versions, gate features.** The phone shows a feature only when `Hello`
   lists its capability; otherwise it shows "Update Side A on your Mac to …". The phone sends its
   own capabilities in `hello` and `DeviceInfo`; the Mac uses them to skip sending what the phone
   can't use (e.g. no `transcript.*` to a phone without `transcript.stream`), never to change the
   shape of a type.
4. **Hard floors are rare.** `Hello.minClientBuild` makes the phone show "Update Side A Remote"
   and stop; the phone carries its own `minMacBuild`. Each is raised only for a security fix.
   Requests from a phone below the floor get 426 `upgrade_client`.
5. **Fixtures freeze.** A fixture file, once in a release, is never edited (see Test plan). A
   change that breaks an old fixture's decode breaks rule 1.
6. **Server-computed text.** `headline`, `detail`, `title`, `summary` and `abilities` come from the
   Mac so an older phone shows new cases correctly without knowing them.

## Client sync (SideARemoteKit)

The stream is for speed, the paged fetch is the truth (Paseo's model), and every mutation goes
through an outbox with an idempotency key (Happy's model).

```swift
public struct Endpoint: Sendable, Hashable, Codable {
    public let macID: String
    public let baseURL: URL                  // https://100.101.102.103:47800 (or the MagicDNS name)
    public let alternates: [URL]             // other addresses from pairing (MagicDNS, LAN), tried in order
    public let serverKeyHash: String         // pinned SPKI SHA-256, base64url; every connection checks it
    public let name: String
}

public protocol CredentialStore: Sendable {   // keychain group shared with the extensions
    func token(for macID: String) async throws -> String?
    func setToken(_ token: String?, for macID: String) async throws
}

public enum Connection: Sendable, Equatable {
    case idle, connecting, live(since: Timestamp), offline(retryAt: Timestamp, reason: String)
    case unpaired, needsUpdate(mac: Bool)
}

/// Everything the UI shows for one Mac, value-typed so it crosses actors freely.
public struct RemoteState: Sendable, Equatable {
    public var hello: Hello?
    public var connection: Connection
    public var epoch: String?
    public var seq: Int
    public var sessions: [SessionKey: RemoteSession]
    public var finished: [SessionKey: FinishedSession]
    public var requests: [RequestID: RemoteRequest]   // open only; resolutions apply removals
    public var resolved: [RequestID: RequestResolution]   // last 50, for "Answered on Mac"
    public var hosted: [String: HostedSession]
    public var accounts: [String: RemoteAccount]
    public var sliceSeq: [Slice: Int]        // freshness of each slice refreshed over REST; never moves `seq`
    public var outcomes: [String: OutboxOutcome]   // outbox item id → how it ended (done, answeredElsewhere, unknown, failed)
    public var pending: [Outbox.Item]        // optimistic: answers and replies not yet confirmed
}

public enum Slice: String, Sendable, Codable { case sessions, requests, hosted, accounts }

public actor SyncEngine {
    public init(endpoint: Endpoint, credentials: CredentialStore, outbox: Outbox,
                transport: Transport = URLSessionTransport())   // pins endpoint.serverKeyHash in its delegate

    public func start()
    public func stop()
    public var state: RemoteState { get }
    public nonisolated var updates: AsyncStream<RemoteState> { get }   // coalesced, at most every 16 ms

    // Presence (drives push suppression).
    public func setForeground(_ foreground: Bool)
    public func setViewing(_ session: SessionKey?)

    // Transcripts.
    public func transcript(_ session: SessionKey) -> TranscriptFeed
    public func message(_ session: SessionKey, seq: Int) async throws -> TranscriptMessage

    // Mutations: enqueue, return at once with the item; results arrive through `updates`.
    @discardableResult public func answer(_ request: RequestID, _ answer: RemoteAnswer) async -> Outbox.Item
    @discardableResult public func reply(_ session: SessionKey, _ reply: RemoteReply) async -> Outbox.Item
    @discardableResult public func interrupt(_ session: SessionKey) async -> Outbox.Item
    public func startHosted(_ start: StartHosted) async throws -> HostedSession   // not queued; needs the Mac now
    public func upload(_ data: Data, mime: String) async throws -> Upload

    public func refresh() async throws       // GET /v1/state, replaces state wholesale
}

/// One session's transcript: a window of messages kept correct against the paged API.
public actor TranscriptFeed {
    public nonisolated var updates: AsyncStream<TranscriptWindow> { get }
    public func loadLatest() async throws
    public func loadEarlier() async throws
    public func close()                      // unsubscribes
}

public struct TranscriptWindow: Sendable, Equatable {
    public var generation: String
    public var messages: [TranscriptMessage] // contiguous by seq
    public var hasEarlier: Bool
    public var repairing: Bool
}

public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func socket(_ request: URLRequest) -> any SocketConnection
}
```

### State rules

- `start()` calls `GET /v1/hello`, then opens `/v1/ws/events` with the stored `epoch` and `seq`.
  A `snapshot` (or `GET /v1/state`) replaces `sessions`, `finished`, `requests`, `hosted` and
  `accounts` wholesale and sets `epoch` and `seq`.
- **The global `seq` advances only two ways:** applying the next contiguous event (`seq + 1`, same
  epoch), or taking a complete `StateSnapshot`. Nothing else moves it. A gap closes and reopens
  the socket with the old `seq` (the server repairs from the ring or a snapshot).
- A REST list (`/v1/sessions`, `/v1/accounts`, …) refreshes only its slice: if its `seq` is newer
  than both `seq` and that slice's `sliceSeq` (same epoch), it replaces the slice and records
  `sliceSeq[slice]`; it never changes `seq`. Events with `seq ≤ sliceSeq[slice]` for that slice
  are then skipped as already reflected. So refreshing accounts while disconnected can't make the
  next connect skip a request event that came before it.
- On `request.resolve` the request moves to `resolved`; if an outbox answer for it is pending and
  the resolution isn't from this device, the item is dropped and the UI shows "Answered on Mac" or
  "Answered in the terminal".

### Transcript gap repair

For each open `TranscriptFeed`, with `last` the highest contiguous `seq` held and `cursor` the
latest opaque `after` cursor received (from a page or a delta; never built by the client):

```
on open:            page = GET transcript (latest page); cursor = page.after; subscribe {session: cursor}
on append(d):       if d.generation differs -> reset
                    if d.messages.first.seq <= last + 1 -> merge by seq (replace overlaps), advance last,
                                                             cursor = d.cursor
                    else -> repair
on replace(d):      replace held messages with the same seq; ignore seqs not held; cursor = d.cursor
on reset:           drop the window, GET latest page, cursor = page.after, resubscribe
repair:             repairing = true; buffer incoming deltas
                    loop: page = GET transcript?after=cursor
                          if page.reset -> reset
                          merge page.messages and page.replaced; cursor = page.after
                          if !page.hasMoreAfter break
                    apply buffered deltas with seq > last; repairing = false
on reconnect:       resubscribe with cursor (the server sends new rows, revised rows, or reset)
```

The phone paces assistant text in on screen (Paseo's reveal); that is a view concern and never
changes the window.

### Outbox

```swift
public actor Outbox {
    public struct Item: Codable, Sendable, Identifiable, Equatable {
        public let id: String                // also the Idempotency-Key
        public let macID: String
        public let method: String
        public let path: String
        public let body: Data
        public let createdAt: Timestamp
        public var attempts: Int
        public var lastError: APIError?
        public let expiresAt: Timestamp      // answers: 24 h; replies and interrupts: 10 min
    }
    public init(file: URL) throws            // the App Group SQLite database, shared by the app, extensions and App Intents
    public func enqueue(_ item: Item) async
    public func items(for macID: String) async -> [Item]
    public func remove(_ id: String) async
}
```

- **Cross-process storage.** The app, the notification action handler, the Content Extension and
  App Intents can each run at once, and an actor protects only its own process. So the outbox is
  a table in `shared.sqlite` in the App Group (WAL mode), and every read-modify-write (enqueue,
  claim for sending, record an attempt, remove) is one short `BEGIN IMMEDIATE … COMMIT`
  transaction. No transaction is ever held across an `await` or into suspension (an app holding
  a lock in a shared container when suspended is killed). A sender claims an item by setting
  `claimedBy`/`claimedAt` in that transaction, so two processes never post the same item at
  once; a claim older than 30 s is free again. The widget snapshot and the decrypted request
  cache live in the same database under the same rule.
- A notification action or App Intent that can't reach the Mac within 10 seconds leaves its item
  for the app.
- Drained in order per Mac while connected; answers first. Backoff as for sockets.
- 2xx or an `Idempotent-Replay`: done. 409 `already_resolved`: done, shown as answered elsewhere.
  An error with `retryable: true` (429, 503, `in_progress`) or a network error: retried with
  backoff until `expiresAt`, then dropped with "Not delivered". 409 `outcome_unknown`: stopped,
  never retried, shown as "May not have reached the Mac" with the session to check. Any other
  error: dropped, shown on the row it came from. 401: stop draining, show "Pair again".
- Items are applied optimistically: an answered request is hidden from `requests` while its item
  is pending and comes back with an error if the item fails.

## Test plan

### Shared fixtures

`Packages/SideAProtocol/Sources/SideAProtocolFixtures/Fixtures/v1/` holds one JSON file per type and variant, named
`<Type>.<variant>.json` (`RemoteRequest.question-multi.json`, `IslandAction.patch.json`,
`ServerEvent.transcript-replace.json`, `APIError.already-resolved.json`, …). The
`SideAProtocolFixtures` target exposes them:

```swift
public enum Fixtures {
    public static func data(_ name: String, version: String = "v1") throws -> Data
    public static func names(version: String = "v1") -> [String]
}
```

- **Round trip** (`SideAProtocolTests`): every fixture decodes into its type, re-encodes with
  `.sortedKeys`, and equals the file's canonical form byte for byte. A test fails when a fixture
  exists for no type or a wire type has no fixture.
- **Every case**: each `IslandAction` case, each `RemoteAnswer` case, each `ServerEvent` and
  `ClientMessage` case, each `TermControl` case.
- **Forward compatibility**: `Fixtures/v1/future/` holds the same objects with extra keys, unknown
  open-enum values, an unknown action kind, an unknown event type and an unknown risk; all decode,
  with `.other`, `.unknown` and `.destructive` where expected.
- **Frozen**: `Fixtures/v1/MANIFEST` lists the SHA-256 of every fixture. CI fails if a listed file
  changed or disappeared; new files are appended. At each release the fixtures are also checked
  against the previous release tag's decoders (CI checks out the tag's package and decodes the
  current fixtures with it), which is what a phone that hasn't updated will do.

### Mac (`SideATests`)

- **Builders**: `RemoteRequest(pending:)` from the island's preview request and real hook
  messages already in `IslandTests` matches the fixtures; `RemoteSession(live:island:hosted:)`
  for working, waiting, finished, Codex and headless sessions, including `abilities`.
- **Answer mapping**: each `RemoteAnswer` against a request fixture produces the exact
  `IslandAnswer.line` the island produces today (questions joined with ", ", `acceptEdits` adds the
  `setMode` rule, `always` sends the stored rule). Each 422 reason has a case.
- **Server contract**: `RemoteServer` on a random port with a test TLS identity and fake stores;
  the test client pins its key, and a client pinning another key fails the handshake. Missing and
  revoked tokens give 401; idempotent replay returns the same body with `Idempotent-Replay`; a
  replay after a new `RemoteServer` on the same idempotency database still replays; a `started`
  record from a previous process gives 409 `outcome_unknown` and the handler doesn't run; a
  second answer gives 409 with the first resolution; cursor paging walks a transcript in both
  directions; `after` with an old revision returns the revised rows in `replaced`; a rebuilt view
  gives `reset: true`; `hello` works without a token; the WebSocket upgrade on the REST port
  routes `/v1/ws/events` and `/v1/ws/term/{name}` by path.
- **Pairing**: the comparison code from `PairingTranscript` fixtures matches on both sides; a
  second right-code attempt voids both with 409 `code_busy`; `wait` returns 403 `declined` on
  Cancel and timeout; the token has the `sa1_` form.
- **Delivery table**: every cell of the table, against fake island and hosted stores; a
  follow-up with a stale `turnID` is 409 `turn_changed` and wakes nothing.
- **Events**: replay from the ring vs snapshot at the boundary (500 events, 10 minutes, new
  epoch); an overflowing slow client is closed with 4008; presence expires after 45 seconds.
- **Terminal**: a resent input frame after reconnect is applied once; a gap closes with 4422;
  after a server restart `ready` carries the new epoch, and after 120 s `applied` is nil.
- **Bridge**: `sessions.py show --after` output fixtures under `tests/fixtures/remote/` decode
  into `TranscriptPage` through the builder (Python tests check the bridge side of the same files).

### Client (`SideARemoteKitTests`)

A scripted `Transport` fake plays REST responses and socket frames.

- Snapshot then events; a seq jump causes a reconnect with `lastSeq`; an epoch change causes a
  snapshot.
- Transcript repair: a delta after a gap triggers `after` fetches until `hasMoreAfter` is false,
  buffered deltas apply once, nothing is duplicated; `transcript.reset` and 410 restart the window.
- Outbox: items survive a new `Outbox` on the same database; two `Outbox` instances (standing in
  for two processes) enqueueing at once lose nothing; a claimed item isn't sent twice; 409 drops
  with "answered elsewhere"; 503 and `in_progress` retry with backoff until `expiresAt`;
  `outcome_unknown` stops without a retry; the same `Idempotency-Key` goes out on every attempt.
- State: a REST slice refresh newer than `seq` doesn't move `seq`, and the next replay still
  applies an earlier event of another slice.
- Terminal: a `ready` with another epoch or `applied: nil` discards unacked frames and raises the
  notice; nothing is resent.
- Close codes map to the right `Connection` state (4401 → `.unpaired`, 4426 → `.needsUpdate`).

## Open questions

1. **Question drafts across devices.** The island keeps half-answered forms per request; the
   phone keeps its own. Sharing drafts (a `PUT /v1/requests/{rid}/draft` and a `request.draft`
   event) is left out of v1.
2. **Slash commands through a Stop hook.** Whether `/model …` sent as a follow-up wakes Claude Code
   as a command or as plain text. Until checked, `/model` and `/effort` are offered only for hosted
   sessions.
3. **Session keys that change.** `/clear` gives a session a new conversation id under the same
   process. The spec replaces the row (`session.remove{replacedBy}`); the phone could instead keep
   the row and show the history as a fold. Decide with the transcript design.
4. **Multiple Macs.** Everything above is per Mac (`macID` on `Endpoint` and outbox items). Whether
   the Sessions tab merges several Macs in M0 or later is a UI decision; the protocol allows both.
5. **ATS with a pinned self-signed key on an IP literal.** The plan is no ATS exception: the
   `URLSession` delegate does the pin check and accepts the trust itself. Confirm on iOS 26 that
   this works for `https://100.x.y.z:47800` and for `URLSessionWebSocketTask` on the same session
   before M0; the fallback is a narrow `NSExceptionDomains` entry, which an IP literal can't use,
   so it matters.
6. **Codex while busy** (hosting open question 7) decides the `auto` cell for working hosted Codex
   sessions, `.queued` until then.
