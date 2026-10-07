# Validation — 2026-09-06

## Executed locally

- Swift 6.3.3 / Xcode 26.6, Apple Silicon Mac.
- Blender 5.2.1 generated the editable `.blend`, 50 evaluated mesh objects, and
  the reference render. The native view renders those meshes with a dynamic LCD.
- 23 Python tests passed, including six real PTY-supervisor integration cases
  against a deterministic fake Claude executable:
  - Same session ID resumed under the next account after a structured rate limit.
  - Manual switch deferred while a tool/turn remained active.
  - Auto disabled, authentication error, and source account without opt-in did not flip.
  - Unsent input prevented a handoff.
- 6 Swift tests passed for track wrapping, invalid/duplicate identifiers, unsupported
  configuration versions, private persistence, and literal shell-argument round trip.
- Installed Claude Code 2.1.263 accepted `auth status --json` for a fresh isolated
  profile and reported `loggedIn: false`, `authMethod: none`; the existing account
  was not imported or modified.
- Native app opened and was visually inspected. Model scale and lighting refined.
- Native onboarding: empty name disables Continue; a filled name enables it.
- Actual 3D HOLD switch disabled the native transport; pressing it again restored it.
- Actual 3D OPEN latch opened the account onboarding sheet.
- Settings exposed menu-bar-only mode; the same process stayed alive after closing
  the player window. The popover implementation shares the verified account store.

- Release app built successfully; `codesign --verify --deep --strict` passed.
- Packaged bridge and mesh matched their canonical source byte-for-byte.
- Final release app relaunched and rendered the model successfully.

## Remaining acceptance checks

These need real user sign-ins and must not be inferred from fixture tests:

- Browser OAuth completion and verified display of two distinct real accounts.
- Live Claude transcript compatibility and resume across those two profiles.
- A real provider limit and successful live Auto flip.
- Full menu bar popover interaction, VoiceOver narration, and testing on macOS 14/15
  (the development Mac uses a newer macOS version).
- Developer ID signing, notarization, Intel build, and distribution-machine install.

The app is a functional Claude Code preview with these live acceptance limits,
not a Claude Desktop integration. See the v0.3 results below for Codex. Automated handoff deliberately
resumes at the prompt instead of replaying work.

## v0.2 model-only interface

- Removed the header, account inspector, footer, background panel, and visible window controls.
- The standalone view is a transparent 620×620 surface containing only the Blender model.
- Dragging the housing did not activate OPEN; the model remained interactive afterwards.
- Stable accessibility buttons are attached directly to the model. Pressing HOLD
  updated the LCD and disabled the other transport actions; pressing again restored them.
- OPEN displayed onboarding; dismissing it returned to the model-only surface.
- Release build and all 6 native tests passed with no compiler warnings.
- Claude account/session bridge code is unchanged in this release.

## v0.2.1 onboarding copy

- Release build and signature verification passed.
- Visually inspected the compact 400×274 first-step sheet in the running app.
- Accessibility tree contains only its title, close action, labeled name/email
  fields, and Continue. Empty-name validation remains in place.
- Account and session behavior is unchanged. No new tests were added for copy.

## v0.3 providers and account panel

- Final gates: 38 Python tests and 9 Swift tests passed (47 total). Release build
  completed without compiler warnings.

- Swift migration tests verify old Claude profiles retain identity, email, readiness
  and consent. Codex profiles round-trip; unknown providers fail closed.
- Codex protocol and real PTY fixtures cover exact-thread resume, manual switch
  deferral, source consent, typed drafts, pending approvals, auth errors, collaborator
  activity, provider separation, private storage, and metadata filtering.
- The installed Codex 0.148.0 reported no signed-in identity for a disposable profile
  using the Keychain backend. No default login was imported.
- A real unsigned-in app-server created a locally saved conversation, and a second
  disposable profile successfully resumed its exact thread ID using the shared
  managed history index. This is storage compatibility evidence, not live OAuth.
- The real native Codex TUI connected through the private Unix proxy: observed
  initialize, initialized, account/read and account/login/start; its sign-in screen
  appeared without a connection error. No sign-in was completed.
- Visually inspected a separately identified preview build to avoid another older
  preview sharing the production bundle ID. OPEN created an independent Accounts
  dialog. Account rows have a single, unobstructed ellipsis. Claude/Codex selection,
  empty-name validation, and the Codex sign-in action were exercised.
- No real user account was added, removed, signed out, or used for a coding request
  during these tests. Live two-account OAuth and actual limit handoff remain pending.

## v0.4.1 first use and recovery — 2026-09-07

- All local gates passed: 12 packaging/release tests, 38 bridge tests, 16 Swift tests, and 18 website tests (84 total). Both architectures compiled, the website built, and the universal DMG mounted read-only with a valid Applications shortcut. Intel execution was not tested on this ARM host.
- Native preview exercised Add account, empty-name validation, compact installed-tool readiness, Verify, Done, Settings, and a real diagnostic save. The exported JSON contained only its fixed schema and was mode 0600. Preview analytics remained disabled. Auto flip explanatory copy was shortened and made multiline after visual inspection found truncation.
- The analytics integration test captures the actual HTTP payload locally: account verification before consent sends nothing; after consent it sends account_connected. Revocation and demo exclusion still hold. Core tests cover diagnostic canaries for identities and paths.
- One real managed Claude account passed auth status. Two tiny print-mode requests in an empty temporary project were rejected because its organization has disabled Claude subscription access to Claude Code. A separate interactive supervisor attempt reached Claude's initial setup/sign-in screen and was stopped. The browser account differed from the managed account, so no browser authorization was granted and no credentials were replaced.
- No successful real coding turn or account handoff is claimed. A second eligible Claude account and two eligible Codex accounts are still needed for live resume acceptance. Genuine usage-limit handoff, network interruption, and sleep/wake remain unverified. Existing deterministic PTY cases cover safe turns, unsent drafts, pending approvals, authentication failures, and opted-out accounts without exhausting real quotas or disturbing unrelated sessions.
