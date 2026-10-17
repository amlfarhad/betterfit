# Fitbit Air iPhone app: initial research

Date: 2026-09-29. Status: initial research complete; biological-age feasibility investigated further in the linked follow-up. No personal health data has been accessed and no app has been implemented.

## User intent

Build Amal's own subscription-free iPhone app for personal use with Fitbit Air. Prioritize a clean, metrics-focused experience inspired by Whoop and Bevel. Required concepts include recovery, strain, sleep, biological age, useful trends, and home screen widgets. The user explicitly rejected deferring biological age and rejected using Bevel as an alternative. Exclude LLM/chat/coaching, food and water logging, health records, and cycle tracking. Alarms can remain in Google Health. Activity-status logging and manual workout logging have not been decided.

## Findings

- Reviewed the complete Bevel landing page and relevant help articles covering device connections, recovery, strain, sleep, stress/energy, biological age, and customization. Inspected the metric-card visuals in the browser.
- Bevel supports Fitbit data through a direct Google Health account connection. This is integration precedent only; the user wants their own app and does not want a Bevel subscription or recommendation.
- Google Health API is the current successor to Fitbit Web API. The official device compatibility table explicitly includes Fitbit Air and lists heart rate, daily HRV, HRV, daily resting heart rate, sleep, exercise, steps, respiratory rate, oxygen saturation, temperature, and VO2 max types. Listing is evidence of supported types, not evidence that this user's account has complete measurements for all of them.
- Historical health data reaches third-party apps after the Fitbit/Google Health sync. Plan the health-data path as Fitbit Air -> Google Health -> Google Health API -> iPhone app. Do not promise direct replacement of the device-sync app or continuously live dashboard data. Separate optional heart-rate broadcasting is not a substitute for this historical-data path.
- API access requires a Google Cloud project, enabled API, OAuth client, user consent, and appropriate scopes. A personal test integration can use an allowlisted test account. Google documents seven-day refresh-token expiry while the OAuth project is in Testing. Public release has additional verification requirements.
- Historical import is supported; paginate and chunk requests. Recent data should appear before a longer history backfill completes. Missing data must remain missing, not become zero or a fabricated score.
- Bevel recovery uses sleep and physiological metrics; strain uses intensity and duration, with separate treatment of muscular effort. These concepts can inform our own transparent heuristics but do not confer equivalence or validation of our scores.
- Bevel biological age is an estimate with confidence affected by available data, including blood biomarkers. Reproducing an age number from a few arbitrary wearable weights would not be justified.

## Candidate direction, pending discussion

Native SwiftUI iPhone application with Swift Charts and WidgetKit. Local storage and deterministic calculations; no LLM or additional health-data server intended. Validate a native OAuth client and direct API access before finalizing that architecture. Use read-only permissions for sleep, fitness/activity, and health metrics; store credentials in Keychain, never in source control.

Home: three prominent score cards, personal-baseline comparisons, a compact vital-signs strip, recent activity, and visible data freshness. Tapping a score shows contributing measurements, coverage, and trends. Prefer short factual labels and charts over generated prose. History offers daily and longer-term views. Widgets show latest valid scores with timestamps.

Core candidates: a recovery estimate against a personal baseline, cardiovascular strain from heart-rate intensity and duration, sleep duration/consistency/efficiency with stages where available, weekly activity/load trends, and underlying vital trends. Baseline window, minimum coverage, score scaling, and weights require an explicit specification and meaningful tests before use. Import existing history where available; expose calibration state when history is insufficient. Sleep restlessness must not be silently relabeled REM.

Biological age is required in the first release. Investigate and specify a wearable-derived estimate with clear methodology, input coverage, and limitations; do not present a custom heuristic as a validated clock. See [biological-age feasibility](2026-09-29-biological-age-feasibility.md). Stress/energy composite scores remain undecided. For lifting, a cardiovascular score alone must not claim to quantify muscular load. An optional short effort rating may be useful; workout mix is the current clarification question.

## Environment and next steps

- Workspace initially empty except for an uncommitted Git repository on master.
- `swift --version`: Swift 6.4 available.
- `xcodebuild -version`: fails because the active developer directory is CommandLineTools; no `/Applications/Xcode*.app` found. iOS compilation and simulator verification have not been performed.
- No application source, credentials, Xcode project, or health-data import exists yet.
- Next: confirm the first-release design and training needs; specify scoring and data contracts; create the native project; prove a small real-data read with the user's authorization; implement the dashboard, detail/history views, and widgets; validate missing-data behavior and calculations; test/install using Xcode and an appropriate Apple signing setup.

## Primary sources

- [Bevel product page](https://www.bevel.health/)
- [Bevel device connections](https://help.bevel.health/en/articles/10400449)
- [Bevel recovery](https://help.bevel.health/en/articles/11258177)
- [Bevel strain](https://help.bevel.health/en/articles/11257857)
- [Bevel sleep](https://help.bevel.health/en/articles/11258625)
- [Bevel stress and energy](https://help.bevel.health/en/articles/11258369)
- [Bevel biological age and confidence](https://help.bevel.health/en/articles/11586369)
- [Bevel tab customization](https://help.bevel.health/en/articles/10417153)
- [Google Health API](https://developers.google.com/health)
- [Fitbit Air compatibility](https://developers.google.com/health/data-types/device-compatibility)
- [Data types, availability, and historical queries](https://developers.google.com/health/data-types)
- [Google Cloud and OAuth setup](https://developers.google.com/health/setup)
- [Developer checklist](https://developers.google.com/health/developer-checklist)
