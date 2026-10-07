# Side A — design contract

A native macOS account player for people with multiple Claude Code logins.
The object is an original late-1990s Discman-inspired design, modeled in Blender;
not a Sony product or an exact replica of a particular model.

## Reference lock
- Sony portable CD players: circular silver lid, inset LCD, physical transport,
  spring-loaded open latch, HOLD switch. Product reference:
  https://www.sony.com/electronics/support/portable-music-players-other-portable-music-players/d-ej01
- macOS Music mini player: one persistent current item, compact transport,
  secondary library, keyboard equivalents.
- Native macOS setup assistants: one decision per step, explicit external sign-in,
  verification before completion, retry without throwing away a profile.
- Refero bundled craft and motion guidance: visible keyboard focus, persistent
  labels, short state feedback, reduced-motion alternative.

## Decisions
- The physical object IS the standalone window. Everything outside its silhouette
  is transparent. No header, sidebar, footer, title bar, traffic lights, or visible
  duplicate transport. Setup appears only after OPEN.
- Ink #212522, cool gray #E7E9E8, LCD #B7C49C, orange #E86B32 for play only.
- SF Pro for the native chrome, monospaced LCD and technical status labels.
- Previous/next selects a profile; play starts or requests a safe session switch.
- OPEN physically hinges the lid and opens the account library.
- HOLD locks transport; MODE toggles opt-in automatic handoff.
- Menu bar offers the same actual account state and safe-switch actions.
- Onboarding: explain isolation, name a profile, browser sign-in through Claude,
  verify identity, optionally allow that account in automatic handoffs.
- No invented usage percentages. Rate limits are event-driven, with an explicitly
  labeled local cooldown rather than a claimed provider reset time.
- The LCD identifies Claude or Codex for the selected profile. Provider choice lives
  in compact onboarding; account switching stays within that agent.

## Onboarding copy

Use a compact single-column sheet. Keep field labels, sign-in/verification actions,
verified identity, and a short Auto flip access note. No slogan panel, branded
footer, repeated headings, numbered explanations, or planned-feature promotion.
