# Security and privacy

Side A only reads logins. It never writes, copies or refreshes one.

- **Logins stay where their CLI keeps them.** The Mac's own Claude login is Claude Code's
  default Keychain item; other accounts use their own profile item. Codex logins stay in
  `~/.codex` or the account's profile.
- **What it reads:** each account's access token, to call the usage and profile endpoints
  the CLIs use, and the Codex id_token, to name the account. Every read checks that the
  token belongs to that account and refuses one it cannot verify.
- **What it writes:** its own folder in `~/Library/Application Support/SideA`; one marked
  line in `~/.zshrc` if you turn on Switch in Terminal; one Claude Code hook in
  `~/.claude/settings.json` if you turn on instant switching. Both can be turned off in
  Settings and are removed cleanly.
- **Tokens are never logged, printed, uploaded or put on a command line.** The identity
  cache stores a hash prefix of each token, never the token.
- **Starting a 5-hour window** runs the CLI with one short Haiku message; the CLI refreshes
  its own login if it needs to.
- **Analytics** are off unless you opt in, and never include account data.
- **Updates** are Ed25519-signed (Sparkle), and installers are Developer ID signed and
  Apple notarized.

Report a vulnerability privately through GitHub's security advisories on
[arnenoori/side-a-source](https://github.com/arnenoori/side-a-source/security/advisories/new).
