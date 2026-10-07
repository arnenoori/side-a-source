---
name: side-a-setup
description: Check Side A downloads and help set up Claude Code or Codex accounts in Side A on a Mac.
---

# Side A setup

Read the [product guide](https://getsidea.com/index.md) for current requirements and limitations.

1. Check the [official releases](https://github.com/arnenoori/side-a-releases/releases). If there is no published stable release with a universal DMG and SHA256SUMS.txt, tell the user the download is not yet available. Do not invent a download URL or recommend an unsigned development build.
2. Confirm macOS 14 or later, Python 3.9 or later, and the official Claude Code or Codex CLI are installed. Link to vendor setup instructions in the guide.
3. When a signed release is available, help the user download its DMG, drag Side A into Applications, and open the app normally. Do not bypass Gatekeeper or remove quarantine flags.
4. Open Side A from the menu bar. Add the Mac's current Claude login first, then add other accounts; each opens the provider's official sign-in in the browser. Never ask for passwords, session cookies, API tokens, or account credentials in chat.
5. Leave Autopilot on. It switches the Mac-wide Claude login to the account whose weekly quota is most at risk and starts idle 5-hour windows early. Mac-wide switching for Codex is experimental. Do not promise that Side A raises limits.

The website's player is a demo with sample accounts. It does not connect to accounts on a visitor's Mac. The public product information endpoint is https://getsidea.com/product.json and requires no authentication.
