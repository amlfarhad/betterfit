# BetterFit widgets: capability and signing check

Checked October 2, 2026 with Xcode 27.0 (27A266a). No enrollment, purchase, account change, or entitlement bypass was performed for this investigation. Only provisioning metadata was inspected; no account tokens or phone health cache were read or exported.

## Current Apple documentation

Apple's [supported iOS capabilities matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) currently marks **App groups** and **Keychain sharing** available in all three columns: Apple Developer Program, Apple Developer Enterprise Program, and the no-cost **Apple Developer** account column. The checkmarks are HTML `figure` elements and disappear from some text extractors; both original table rows were inspected. Therefore a blanket claim that these widgets require paid membership is not supported by the current matrix.

An iOS App Group still needs registration and provisioning for both the containing app and extension. Apple's [App Group configuration guide](https://developer.apple.com/documentation/xcode/configuring-app-groups) documents the shared container used by the implementation. The eligibility table alone does not prove that the local team can successfully provision this particular identifier.

[Keychain Sharing](https://developer.apple.com/documentation/xcode/configuring-keychain-sharing) is a separate documented mechanism for sharing sensitive items between a developer's targets. Apple explains [how access groups and default groups work](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps). It is a legitimate fallback to investigate if App Group provisioning fails, not grounds to remove required entitlements or transfer authentication tokens to widgets. An alternate transport would need an explicitly scoped snapshot item and preservation of the existing private token group's behavior.

## Installed local profile metadata

The existing iOS profile is named `iOS Team Provisioning Profile: com.amal.form`:

| Field | Observed value |
| --- | --- |
| Team / application prefix | `W4NK2PNZLG` |
| Application identifier | `W4NK2PNZLG.com.amal.form` |
| Local provisioning | `true` |
| Expiration | October 9, 2026, 21:34:56 UTC |
| Provisioned devices | One; identifier omitted |
| Application groups | Absent |
| Allowed keychain groups | `W4NK2PNZLG.*` |

This profile is evidence for the existing Personal app, not proof of a signed widget. Its lack of an App Group explains why it cannot by itself sign the current App Group build. The wildcard keychain allowance is consistent with investigating Keychain Sharing, but the actual extension profile and installed behavior must also be checked.

## Implementation and verified behavior

- `BetterFitRecovery`, `BetterFitActivity`, and `BetterFitSleep` are separate WidgetKit `StaticConfiguration` widgets supporting `accessoryCircular`.
- `BetterFitSummary` supports `accessoryRectangular`. The existing `FormDaily` kind remains for small and medium Home Screen widgets so existing placements keep working.
- Recovery and sleep rings use their 0–100 scores. Activity shows observed higher-heart-rate minutes. Its ring compares with a prior completed-day median supplied by the app, labeled **USUAL DAY**, not a target, capacity, or safety boundary. No baseline produces a dashed ring; no measurements produces a dash, never a fabricated zero. Partial activity coverage suppresses progress fill.
- The backward-compatible optional snapshot fields are `activityMinutes`, `activityBaselineMinutes`, and `activityCoverage` (0–1). The existing `strainStatus` supplies activity readiness. The app should send the usual-day median only after seven eligible prior completed days.
- Saved measurement day, save age, and measurement age determine freshness. Previous-day readings, timestamps over six hours old, and future timestamps beyond five minutes are marked saved. Imported and sample provenance remains explicit. Thirty-minute precomputed timeline entries age the saved state even if a reload is delayed; WidgetKit still controls actual scheduling.
- All views are privacy-sensitive. The extension reads only the bounded shared snapshot and never authenticates or fetches Google data.
- URLs retain the installed `form` scheme: `form://metric/recovery`, `form://metric/strain` (Activity), `form://metric/sleep`, and `form://dashboard`.

Snapshot executable tests passed for legacy decoding, nulls, bounds, provenance, stale days/timestamps, calibration, observed zero, partial coverage, and Activity baseline behavior. Swift 6 typechecking passed against the iOS 17 Simulator target. The complete `FormWidgets` target built successfully for the iOS Simulator with Xcode 27 (arm64 and x86_64); the only warning was the generic target's `ONLY_ACTIVE_ARCH` fallback. Plist lint and diff whitespace checks passed.

A native SwiftUI ImageRenderer render was inspected at circular, rectangular, and Home Screen sizes using synthetic data. Current, partial, stale, and absent states fit without clipping. This is a layout check, not proof of installed Lock Screen behavior. Preserved inspection image: [BetterFit widget layouts](../design/previews/betterfit-widgets.png); build log: `/tmp/betterfit-widget-build.log`.

## Actual provisioning result and remaining phone verification

The project owner's ordinary `Form` app-and-extension automatic provisioning **succeeded with the existing free team**. The resulting profiles and signed entitlements were checked: both authorize `group.com.amal.form`, with application identifiers `W4NK2PNZLG.com.amal.form` and `W4NK2PNZLG.com.amal.form.widgets`. Their profiles expire October 10, 2026 at 01:25:25 and 01:25:26 UTC. No alternate storage transport or paid membership is required for this verified signing route.

The final version5 app and extension were installed on the paired iPhone15, and the app restored existing Google access and completed refreshes. Opt-in status-only diagnostics report `widget_snapshot_saved` after restore/refresh, meaning the shared-file write returned successfully. The device CLI's group-container listing exposed only Library and did not independently show the snapshot, so no widget readback or actual Lock Screen render is claimed. The user still chooses placement through the Lock Screen gallery. Both existing schemes now run the complete widget app, preserving the installed bundle identity.
