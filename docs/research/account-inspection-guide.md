# Account inspection and scoring-first workflow

Status: authorized by Amal on 2026-09-29. OAuth is connected with all four requested read-only scopes. The first real account audit is complete; private findings are in `.private/google-health/account-audit.md`. Settle the calculation engine before building the iPhone app or frontend. Biological age remains required; its numeric model is unresolved.

Account context: Amal reports the Fitbit Air is new and Google Health displays "calibrating, six days left." The exact metric showing the countdown is not yet confirmed. Proceed with OAuth setup and an audit of the history that actually exists; do not assume seven or ninety days are already available. Google's readiness documentation requires seven nights for the first score and recommends a month for a fuller baseline. Our model-specific minimum history and validation are separate from Google's countdown. Recheck data as history accumulates; early missing outputs may reflect calibration rather than unsupported API types. Reference: https://support.google.com/googlehealth/answer/14236710

## What Amal does first

1. Open Google Health on the iPhone and let the Fitbit Air finish syncing. Confirm which Google account holds the wearable data.
2. Open https://console.cloud.google.com/ on the Mac. Select the project **Fitbit Air**, ID `fitbit-air-510120` (Amal's actual project name).
3. Under APIs & Services -> Library, find and enable **Google Health API**. This is the service at `health.googleapis.com`, not the separate Cloud Healthcare API. Do not configure a hosted server, database, or AI service for this audit.
4. Set up Google Auth Platform (or OAuth consent screen) with app name `Fitbit Personal Audit`, your support/contact email, audience External, publishing status Testing. Add the Google Health account as a test user. Review Google's terms yourself when prompted.
5. Under Data Access, add these read-only scopes and save:

   ```text
   https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
   https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
   https://www.googleapis.com/auth/googlehealth.sleep.readonly
   https://www.googleapis.com/auth/googlehealth.profile.readonly
   ```

   They cover activity/workouts/fitness, physiological measurements, sleep, and profile inputs such as age/sex required for model assessment. No write scopes, location, nutrition, or ECG/irregular-rhythm scopes are requested.
6. Under Clients -> Create client (or APIs & Services -> Credentials -> Create credentials -> OAuth client ID), choose **Desktop app** and name it `Mac Data Audit`. Download the JSON file and leave it in Downloads. Tell Codex it is downloaded, or give the local filename. Do not paste its contents, tokens, or your password into chat.

This Desktop client is for local Mac inspection. The later iPhone app will need its own iOS OAuth client. Google's health setup codelab demonstrates a Web application client for OAuth Playground; our local inspection uses Google's documented installed-app flow with a loopback callback instead.

## Local authorization and storage contract

The audit utility is implemented in `fitbit_audit/`. It uses an external/system browser, PKCE S256 and state verification, a short-lived callback listener bound only to 127.0.0.1 on an available port, and minimal read-only scopes. Google performs sign-in; Amal reviews and grants the requested permissions. Do not ask the user to paste a callback URL or token.

Copy credentials into `.private/google-health/` without printing them. That directory is ignored by Git and restricted to the local user; this is not an encryption guarantee. Protect token files with mode 0600 if file storage is used, avoid credentials/raw health values in logs, and prefer Keychain for long-lived credentials. Do not commit health data, include it in public fixtures, or send it to a third-party scoring service. Google documents seven-day refresh-token expiry in OAuth Testing mode; handle reauthorization explicitly.

## Inspection sequence

1. Confirm OAuth success with a small read and report scope availability without printing credentials or raw profile identifiers.
2. Fetch a small recent window (initially seven days) for sleep, daily HRV, daily resting HR, heart rate, steps, activity/workouts, and available VO2 max. Check auxiliary respiratory, oxygen, and temperature types separately. Record permission errors versus empty data distinctly.
3. Extend to roughly 90 days if available for baseline and historical checks, and more only when justified. Paginate fully and respect endpoint-specific date-range limits and rate limits. A short account history is acceptable; do not fabricate earlier readings.
4. Produce a local audit of units, sampling resolution, completeness, recorded source/device, dates, timestamp/offset behavior, overnight sleep attribution, duplicates, manually entered records, and derived versus measured fields. Identify Fitbit Air separately from older wearables and phone data where metadata allows.
5. Check whether minute-level HR/steps and reliable overnight HRV support the intended algorithms. Preserve actual HRV measurement definitions and avoid treating RMSSD and SDNN as interchangeable. Distinguish missing intervals, off-wrist time, and genuine zero activity.

## Score specification deliverables

For recovery, strain, sleep, and biological age, document:

- Exact input definitions, units, source selection, and permitted transformations.
- Scientific references or explicit heuristic rationale; model licensing if applicable.
- Equations, coefficients, bounds, aggregation windows, baseline estimation, minimum history, and update cadence.
- Missing-data/partial-consent/calibration behavior, handling of outliers, time zones, and late-arriving or corrected data.
- Meaning of the output and how the calculation is explained to the user.
- Versioning, deterministic test cases, and evidence for any accuracy claim.

Biological age must be resolved rather than silently deferred. Do not invent coefficients to match an attractive age, pretend a completeness score is an accuracy confidence interval, or claim that one person's data validates biological aging. If a research model's data inputs or parameters cannot be obtained, document that limitation and assess a clearly described custom estimate before locking its numeric specification.

## Backend completion criteria before frontend work

- Real-data retrieval and repeat import work without duplicate records.
- A data-availability audit identifies what this account actually supports.
- Each required score has a versioned, reviewable specification and an implemented calculation independent of the UI.
- Meaningful tests cover insufficient history, gaps, source changes, duplicate imports, time boundaries, and numerical properties relevant to each score.
- Historical runs include score breakdowns and sensitivity checks; input completeness is reported separately from model validity.
- Scientific limitations and unresolved model validation are visible. Biological age is not called clinically validated without supporting evaluation.

## Official setup references

- https://developers.google.com/health/setup
- https://developers.google.com/health/scopes
- https://developers.google.com/identity/protocols/oauth2/native-app
- https://developers.google.com/health/codelabs/make-your-first-api-call-using-oauth2-playground

Completed: Desktop credential validation, browser authorization, bounded paginated retrieval, source/schema inspection, and a repeat daily-HRV read. All 16 selected data types returned successful responses after correcting two filter definitions; empty results are preserved as empty. Credentials, tokens and health records are stored privately and excluded from Git. The audit CLI has 14 passing synthetic unit tests. A single repeat read is not proof of production import idempotence.

Subsequent phase completed: reconciled SQLite storage, normalization, canonical export and the native Swift calculation engine are implemented and tested. See [validation](../validation/2026-09-29-validation.md), [engine API](../engine-api.md) and [model selection](2026-09-29-age-model-selection.md). The frontend and native iOS transport/scheduling are not implemented. Do not treat arithmetic tests or the account audit as clinical validation. No automatic re-import or monitoring is scheduled.
