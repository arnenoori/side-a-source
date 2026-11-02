# First use and recovery

## Requirements

Side A needs Python 3.9+ (standard library only) for its bridge, and the official command-line
app for each provider you add: Claude Code, Codex, or both. Settings > General > Tools shows
each one with its version, or an Install or Update link when it is missing or too old. Side A
finds Python in Homebrew, `~/.local/bin` and Apple's developer tools, including versioned names
such as `python3.14`, and uses the first 3.11 or later it finds before falling back to 3.9 or 3.10
(on those, the island can't read Codex's `config.toml` or managed requirements, so it asks about
calls Codex's reviewer would take). If Python goes missing, Side A checks again every minute and retries
failed readings as soon as it is back.

## Signing in

Settings > Accounts > Add account opens the provider's browser sign-in. Verification runs by
itself when you return. A temporary CLI failure or timeout keeps the last verified state and
never moves a login on its own.

## When an account shows no current numbers

The account's row says why, in words:

| It says | What's happening | What to do |
| --- | --- | --- |
| As of 14:05 | The last reading is over 15 minutes old | Nothing; it updates on the next read |
| Renewing its login… | The login's short-lived token expired; Side A renews it as Claude Code does | Nothing; if renewing fails, sign in again |
| Checking whose login this is · retrying … | The login's owner can't be confirmed yet | Nothing; Side A never uses an unverified login |
| Couldn't connect · retrying … | The read failed (network, endpoint) | Wait for the retry time shown |
| Sign-in ends … · sign in again | The sign-in expires within three days | Sign in again from the account's menu |
| Sign in again | The login was revoked or signed out | Sign in again from the account's menu |

A rate limit from the usage endpoint keeps the last reading instead of showing an error. When
status.claude.com reports an incident affecting Claude Code or the API, the menu shows it: errors
in your sessions then are likely Anthropic's, not your accounts'.

## Dynamic Island

- **Nothing appears:** check Settings > General > Dynamic Island and its **Claude Code permission
  requests** or **Codex permission requests** toggle. **Show a sample request** tests the panel.
- **Codex requests don't arrive:** approve the hook once with `/hooks` in Codex.
- **Go or Show terminal can't find the tab:** the session may have closed, or runs in tmux or over
  SSH. If Warp comes forward on the wrong tab, update Warp; builds without its focus link need Side A allowed in System Settings > Privacy & Security > Accessibility. For
  Terminal, iTerm and Ghostty, allow Side A when macOS asks to let it control them.
- **Notes and stops are refused:** they need the island's Claude Code hooks turned on.

When Side A is closed, the hooks exit at once and the CLI asks in the terminal as usual.

## Diagnostics

Settings > General > Privacy > Save diagnostics… (also in the Help menu) writes a local JSON file
with a schema version, app and macOS versions, architecture, the state and version of Python,
Claude Code and Codex, whether the account library loaded, whether Side A is in Applications,
and why the last update failed. It excludes account details, paths, IDs, conversations, logs and
credentials. The file is created with mode 0600, and Side A never uploads it. Review it before
sharing it.

## Removing Side A

Settings > General > Remove Side A takes its line out of `~/.zshrc`, restores your Claude Code
statusline, removes its hooks from `~/.claude/settings.json` and `~/.codex/hooks.json`, stops
opening at login, deletes its caches and search index, and moves the app to the Trash. Your
conversations aren't touched. Accounts and their logins stay unless you also choose **Also sign
out of and forget my accounts**.
