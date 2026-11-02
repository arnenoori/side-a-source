# Side A — design

Side A is a macOS menu bar app for people with several Claude Code and Codex accounts. These are
the design principles and the decisions that follow from them. For how it works underneath, see
[architecture](architecture.md).

## Principles

- **Uncluttered.** One fact per line, short labels, no slogans or feature promotion. A control
  appears where it is used, not in a separate panel.
- **Real numbers only.** Limits and reset times come from the provider's usage endpoint or from
  Claude Code's own replies. A reading older than 15 minutes says when it is from. Side A never
  guesses a percentage.
- **Never surprise the user's sessions.** Running sessions keep working through a trade. Nothing
  is typed into a terminal. Side A's hooks sit beside the user's own and come out cleanly.
- **Destructive actions need a click.** No shortcut, default button or "Always" approves them.
- **Accessible.** Every control has a VoiceOver label. Motion respects Reduce Motion, and
  the island follows Increase Contrast.
- **Keyboard first where it saves time.** Shortcuts exist for repeated decisions, and only while
  something is waiting for one.

## Menu bar

The menu bar is the main surface. Its icon is a gauge with the tightest limit (5-hour or weekly)
of the account in use. The menu lists every account's 5-hour and weekly limits, plus a weekly
Fable, Opus or Sonnet cap when the account reports one, each with its reset time. Claude incidents
that affect Claude Code or the API show at the top, so a failing session isn't blamed on an
account.

## Settings

Five tabs, each with one job:

- **Accounts:** add, use, rename, sign in again or remove accounts, grouped by provider, with an
  In use label. Each account can be left out of Autopilot.
- **Usage:** tokens by day, project and model, Claude and Codex separately; weekly pace; paid
  usage; what the Claude tokens would cost at API list prices.
- **Sessions:** search and read every conversation; see what is running now.
- **Autopilot:** the live ranking and its rule, Move at, Follow Fable, your day, Switch in
  Terminal, live limits, and the limit hook.
- **General:** Dynamic Island, notifications, sounds, sync, the 3D player, updates, the search
  index, privacy and Remove Side A.

## Dynamic Island

The island lets the user answer a session without finding its terminal.

- A request grows out of the notch. On a display without one it is a pill under the menu bar.
- It shows what will run: the command, or the file and a diff, plus the project and the account.
- The terminal prompt stays open too. Whichever answers first wins; the island then lets go.
- Several requests queue with a counter instead of stacking.
- Destructive commands and edits to credentials or to Claude Code's or Codex's own settings are
  marked. They take no shortcut and offer no Always.
- ⌃⌥ shortcuts are registered only while a request or a finished session is waiting, so they
  never block other apps the rest of the time. ⌃⌥I moves keyboard and VoiceOver focus into the
  island.
- VoiceOver announces each request and which shortcuts apply. Reduce Motion swaps the springs
  for fades.
- A finished session chimes once and waits in a Ready list until the user goes to it. A session
  paused on background work is not shown as finished.
- **Show a sample request** lets the user try it without a session.

## Sessions

- Search covers what was asked, the replies and the commands that ran.
- The list puts what needs the user first: waiting, then running, then pins, then each project.
  Branches sit under the conversation they came from.
- Fast is a feature: the list paints from its last copy, and long conversations open in
  milliseconds at the latest message.
- Pin, rename and archive live in Side A only. Claude's and Codex's files are never touched.
- **Running** names the step a session is on and raises at most one flag (stuck, looping or
  failing) so a glance says which session needs a look. A large context is noted beside an idle
  session and never hides the step.
- Rows never move under the pointer: running sessions keep a fixed order (newest started first,
  by project), and section changes wait while the pointer is over the list.
- A note or a stop reaches a working session at its next step, never mid-step, and can be taken
  back until then.

## Autopilot

Autopilot plans so that quota is spent before it expires, without hurting running work.

- **Spend what expires first.** Rank by weekly percent left ÷ hours until the weekly reset ×
  plan size. Among near-ties, use the account whose 5-hour window resets soonest.
- **Don't flip back and forth.** Keep a usable account unless another is clearly more urgent.
- **Move only to real room.** Trade to an account with room on every limit, unless none has.
- **Move at** (default 95%) is the user's choice, not a hidden constant.
- **Plan each login by its own sessions.** Each running login is planned by the models its own
  sessions use.
- **Fable share.** With Follow Fable on, Fable sessions go to the account with the most Fable
  left. When a login's Fable sessions have spent their account's Fable share and no free account
  has any, trade with a login whose sessions run only other models, if the spent account still
  has room for those.
- **Cache-aware timing.** A moved session loses its prompt cache and resends its whole context.
  So a trade the account doesn't need yet waits until that login's sessions have been quiet for
  five minutes. An account that is out of room moves at once.
- **Trust the session's own limit reply.** Claude Code's limit message counts as proof the
  account is full, even while the usage endpoint is rate-limited.
- **Start windows early, cheaply.** During the user's usual hours, one tiny Haiku message starts
  an idle account's 5-hour window so it resets sooner.
- **Never copy a login.** Logins are traded, not duplicated, because copies invalidate each
  other. Codex accounts are read and primed, never switched.

## 3D player (optional)

An original late-1990s Discman-inspired object modeled in Blender; not a Sony product or a
replica of a particular model. It is off by default (Settings > General > 3D player).

- The object is the window: everything outside its silhouette is transparent.
- Previous and next pick an account; PLAY uses it on this Mac; OPEN hinges the lid and opens the
  accounts; HOLD locks the controls; MODE toggles Autopilot.
- The LCD shows the selected or playing account and the mode (AUTO, MANUAL or HOLD).
- Each control is a VoiceOver element. Reduce Motion turns off the lid and button animations.

## Reversed decisions

- "No invented usage percentages; rate limits are event-driven with a local cooldown." Replaced
  by real limits from the usage endpoint and the statusline (0.5.x).
- "The physical object is the app." Replaced by the menu bar; the player is optional (0.5.3, 0.5.6).
- Per-project Terminal sessions and the PTY supervisor were removed (0.5.3). Running sessions
  now move by trading logins (0.5.19).
- The onboarding sheet with "Auto flip" consent. Replaced by Add account in Settings > Accounts
  and the per-account Include in Autopilot switch.
