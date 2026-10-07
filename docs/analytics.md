# Website analytics

Side A uses the US PostHog project **598589**. The [website dashboard](https://us.posthog.com/project/598589/dashboard/2074027) shows 30 days of visits, download clicks, demo use, and coarse failures.

The native app before 0.4.0 does not collect analytics. Version 0.4.0 adds a separate opt-in described below. The website uses the [public capture API](https://posthog.com/docs/api/capture), without the SDK, autocapture, replay, cookies, or persistent visitor identifiers. Every page load creates a random ID held only in memory. Counts represent visits, not unique people or returning users. PostHog receives no account names, emails, conversation content, URL queries, hashes, or referrers. GeoIP enrichment and person profiles are disabled on every event. Project-level IP discard is enabled; session replay is disabled.

| Event | Trigger | Additional properties |
| --- | --- | --- |
| `$pageview` | Production page loads | None |
| `download_clicked` | Enabled, validated DMG download is clicked | `version`, `format: dmg`, `source: hero` |
| `release_list_opened` | Fallback GitHub release-list CTA is clicked | None |
| `setup_opened` | Setup dialog opens | None |
| `demo_interacted` | A working physical player control is activated | `action`: open, next, previous, play, stop, mode, hold |
| `release_lookup_failed` | GitHub lookup fails | None |
| `demo_load_failed` | Interactive preview fails to initialize | None |

All events have `surface: landing`, `schema_version: 1`, and the canonical homepage URL. Properties and action names are allowlisted at the capture boundary. Network errors are swallowed; analytics never blocks a download. Requests use `keepalive` to survive navigation and omit cookies and HTTP referrers. There is no retry loop.

Only HTTPS `getsidea.com` sends events. Local development, Vercel previews, Do Not Track, and Global Privacy Control are excluded. Visitors can disable statistics in Setup → Requirements → Privacy. Only that opt-out preference is persisted in local storage. Restricted storage fails closed. A reload starts a new visit; browser blockers and opt-outs mean totals are incomplete. Download clicks are not completed downloads or installs; use GitHub release asset counts as a separate download-request metric. Brief launch verification generates real events and should be excluded by date when comparing launch traffic.

## Operations

Use the official CLI:

```sh
npx --yes @posthog/cli@0.18.1 login
npx --yes @posthog/cli@0.18.1 api call --json project-get '{}'
```

Choose US, then Side A. The CLI credential lives outside the repository in `~/.posthog/credentials.json` (mode 0600). Never print it, commit it, or use it in browser code. Dashboard and insight write scopes suffice for maintaining these charts. The `phc_` project token in `site/src/analytics-config.json` is a public write-only ingestion token, not a management credential. Keep CSP ingestion permissions synchronized in the `site/index.html` meta tag, `vercel.json`, and `site/public/_headers`.

Run `npm --prefix site test` and `npm --prefix site run build`. For a production check, open getsidea.com in Arc, open Setup, activate a demo control, click Download, and verify those events with the CLI `execute-sql` tool or PostHog Activity. Check the opt-out control stops subsequent events and persists across reloads. Do not send synthetic success events for a failed action.

## Native app (0.4.0+)

The [app-health dashboard](https://us.posthog.com/project/598589/dashboard/2074258) separates opt-in setup, session, completed handoff, and error counts from website clicks.

App statistics are a separate opt-in, off by default. The toggle appears after connecting an account and in Settings → Privacy. It persists only the user's consent; every app launch creates a fresh random ID in memory. Disabling cancels pending requests, discards that ID, and sends no opt-out event. Demo launches never send events. No website-to-app identity linkage exists.

The only events are `app_launched` (when already opted in), `account_connected` (a profile becomes verified while already opted in) and `account_handoff_ready` (Side A moved the Mac-wide login to another account). No event backlog is stored or replayed on consent.

Properties are `surface: mac_app`, `schema_version`, `app_version`, and the provider enum where applicable. Internal account/session IDs stay in memory and are never sent. PostHog person profiles and GeoIP are disabled; project IP discard remains enabled. Add a `surface` filter when comparing the web and app charts. Event payload and session-state tests live in SideACoreTests; a URLProtocol integration test verifies opt-in persistence, revocation, and demo exclusion without contacting PostHog.

