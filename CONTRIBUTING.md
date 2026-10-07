# Contributing

Use short feature/fix branches and focused pull requests. Keep business logic out
of views, keep the native UI and bridge state contracts documented, and do not add
dependencies when the platform/standard library is sufficient.

Before a PR, run the bridge suite, Swift tests, and release bundle build in README.
Any auth or session change needs fixture tests that prove failure paths as well as
the happy path. Never use a real login or paid model call in CI. Record which live
acceptance checks remain unverified. New UI actions need native keyboard/VoiceOver
equivalents, and motion must respect Reduced Motion.

The Blender script is the source for exported geometry. Preserve the `.blend` and
reproduce the export when changing the object. Do not hand-edit the generated JSON
or the copied bridge resource. Never commit Application Support data, credentials,
.env files, conversations, or build products.
