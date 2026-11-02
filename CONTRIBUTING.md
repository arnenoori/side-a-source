# Contributing

Use short feature/fix branches and focused pull requests. Keep business logic out
of views, keep the native UI and bridge state contracts documented, and do not add
dependencies when the platform/standard library is sufficient.

Checks run on your Mac, not GitHub Actions. `git config core.hooksPath .githooks` once per clone runs
`scripts/check.sh` before each push, with the gates the changed files need; `scripts/check.sh --all` runs them all.
`scripts/dev.sh` runs your checkout in place of the installed Side A and puts the installed one back when it quits.
A change a Mac user would notice adds a paragraph under `## Unreleased` in CHANGELOG.md in the same PR;
`scripts/check-release.py` refuses a release whose version has no changelog section, or that leaves
Unreleased entries behind.
Any auth or session change needs fixture tests that prove failure paths as well as
the happy path. Never use a real login or paid model call in CI. Record which live
acceptance checks remain unverified. New UI actions need native keyboard/VoiceOver
equivalents, and motion must respect Reduced Motion.

Anything Side A adds to a file the user owns (`~/.zshrc`, `~/.claude/settings.json`,
`~/.codex/hooks.json`) must carry its marker (`side-a shell integration`,
`side-a-live`, `side-a-limit`, `side-a-island`), sit beside the user's own entries, be
removed cleanly by its toggle and by Remove Side A, and leave the CLI behaving
normally when Side A isn't running. Hooks that run on every tool call must stay cheap:
the island's mail hooks cost one file test unless mail is waiting. Try UI changes with
`--demo`, which shows fictional accounts and sessions and must never write outside its
temporary folder. Update `docs/` and `SECURITY.md` when behavior, files touched, or
network requests change.

The Blender script is the source for exported geometry. Preserve the `.blend` and
reproduce the export when changing the object. Do not hand-edit the generated JSON
or the copied bridge resource. Never commit Application Support data, credentials,
.env files, conversations, or build products.
