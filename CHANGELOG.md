# Changelog

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
