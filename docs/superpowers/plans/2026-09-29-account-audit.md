# Google Health Account Audit Implementation Plan

**Goal:** Authorize Amal's Fitbit Air account locally and inventory the available measurements before scoring or UI implementation.

**Architecture:** A Python standard-library CLI performs installed-app OAuth with a localhost callback, PKCE, and CSRF protection. A separate read-only API client imports bounded, paginated windows into owner-only, Git-ignored storage and reports coverage without printing credentials or full health records.

**Tech Stack:** Python 3.14 standard library; Google OAuth 2.0 and Google Health API v4. Execute inline in the existing empty project on `codex/account-audit`; no separate worktree is needed because no app implementation exists.

## Accepted scope

The user authorized account inspection and backend preparation before any app/frontend development, followed the setup guide, and downloaded Desktop credentials. Cloud project display name is Fitbit Air; credential project ID is `fitbit-air-510120`. Fitbit is new and reports six calibration days remaining. Credential contents and health data remain in `.private/google-health/`.

## Tasks

- [x] Add tests for PKCE (RFC vector), rejection of callback state mismatch, endpoint pinning, owner-only writes, and pagination completion/loop detection. Run `python3 -m unittest discover -s tests -v` and verify the new functions are initially absent.
- [x] Implement `fitbit_audit/oauth.py`: installed credential loading, fixed Google endpoints, local callback listener, state + PKCE, exact read-only scope set, token exchange/refresh, private token storage, bounded timeouts and sanitized errors. Test against deterministic local fixtures; no live token values in test outputs.
- [x] Implement `fitbit_audit/api.py`: GET-only requests to fixed Health host, explicit allowlisted metric types, time-window filters based on interval/sample/daily/sleep semantics, bounded retries for 429/5xx, full pagination with repeated-token protection, and separate error/empty/partial states.
- [x] Implement `fitbit_audit/__main__.py`: `auth` and `inspect` commands. Save raw pages and local audit summaries privately. Print only counts/coverage/status, not identity or token data. Test syntax and CLI help.
- [x] Launch OAuth, open the localhost authorization page in a supported external browser, and hand Google account selection/permission grant to Amal. Verify completion using a local status file, never a pasted callback URL.
- [x] After consent, inspect a seven-day window of real data; distinguish permission/configuration errors from absent or calibrating metrics. Inspect schemas/units and relevant record shapes without printing full raw pages. Update the private report and project handoff.

## Verification and boundaries

Use synthetic fixtures for automated tests. Reject non-Google credential endpoints and unsafe paths. Never write to the health account. OAuth token POSTs are limited to Google's token endpoint. Do not calculate health scores from unvalidated inputs or infer that a missing metric is unsupported. Formula selection, biological-age model validity, historical scoring, and app UI remain subsequent work; no numeric score engine is claimed complete by this plan.

Reference: https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list
Reference: https://developers.google.com/identity/protocols/oauth2/native-app

## Result

Authorization and the initial read-only audit completed on 2026-09-29. All 16 selected metric types returned successful responses (some empty); two live filter errors were corrected and regression-tested. Fourteen synthetic tests pass. Detailed account findings stay in `.private/google-health/account-audit.md`; `docs/research/data-input-contract.md` records the technical implications without personal measurement values. Score formulas remain subsequent, unfinished work.
