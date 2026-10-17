# BetterFit: a clearer daily health dashboard

User authorized a substantial upgrade while preserving the smooth, dark, minimal visual direction. User chose BetterFit. Remove all A-shaped branding. Preserve current build as a recovery point before changes (done: commit3437b77, tag form-build4-stable, private signed build4 copy). No new subscription, chat/LLM, food, water or cycle features.

## Product decisions

The dashboard should explain last night's sleep, recovery relative to the user's own baseline, and accumulated cardiovascular activity. Lead with observed minutes, sleep duration/target, baseline differences and coverage. The existing 0–21 Strain heuristic is not WHOOP's formula or a danger scale; demote it to detail, label it an app estimate and explain intensity-duration contributors. Use Activity as the primary user-facing label, preserve the old calculation for continuity and roll back support. Keep biological age as the qualified movement estimate.

Add native reads for daily oxygen saturation, respiratory rate and sleep temperature under existing consent. Expand sleep details with actual available stage summaries, without treating restlessness as REM. Describe deviations as changes from the personal baseline, not disease diagnosis or all-clear. Insufficient history and absent streams are explicit. No inferred blood pressure or rhythm diagnosis. Official Google guides list BP trends as a separate proprietary upcoming Air feature, not an available public data type; IRN needs a separate consent scope and source feature.

Design retains graphite/ivory with lime recovery, blue activity and violet sleep. Editorial typography; measured visual hierarchy; limited atmospheric gradients; original non-letter icon. Dashboard cards explain numbers inline, health signals have personal ranges, and drilldowns show method/source/quality. No chatbot or generated coaching paragraphs. Remove welcome/login-like startup artwork: a restrained dashboard skeleton preserves place during restore; connected sessions never show onboarding. A compact validated presentation cache may hydrate before raw-history processing, bounded and source-fenced.

## Data and compatibility

Existing raw cache is retained for rollback. New raw cache uses health-cache-v2.json, seeded read-only from the legacy cache if absent; account switching/disconnect clears both. New DailyInput optional fields: oxygenSaturationPercent, respiratoryRateBrpm, skinTemperatureCelsius. New SleepInput optional fields: lightMinutes, deepMinutes, remMinutes, startTime, endTime. Existing scores unchanged unless a demonstrated formula defect requires a separately versioned correction. Additional streams retain pagination, local dates, replacement validation, failure isolation and bounded concurrency. No tokens or private account payloads in logs or checked-in artifacts.

## Widgets

Implement separate circular Lock Screen recovery/activity/sleep widgets and a compact rectangular summary, with honest no-data/calibrating states and deep links. Existing Home Screen widgets remain. Use native WidgetKit and legitimate shared storage. Verify current Personal Team signing capability before claiming live widgets install. Do not buy enrollment, change account settings or weaken platform entitlements to bypass limitations. All implementation and simulator verification can proceed even if phone provisioning is unavailable.

## Success criteria

1. Recoverable baseline documented and tested by identity/hash.
2. BetterFit display name, icon and in-app branding; no A monogram.
3. No login-like screen flash for a returning connected user.
4. Main dashboard explains activity, recovery and sleep without interpreting high load as danger.
5. Additional available vitals and sleep metrics flow from API through validated storage to trends/details; missing remains missing.
6. Meaningful regression tests, signed Release install and cold-launch check; visuals inspected at phone sizes.
7. Lock Screen widget code/build/preview complete; actual signing/install result reported accurately.
