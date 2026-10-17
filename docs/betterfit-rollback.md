# Restore the previous Form version

The pre-redesign app is preserved by Git tag `form-build4-stable` at commit `3437b77`. The BetterFit work is on `codex/betterfit`.

An exact copy of the previous signed build4 app is retained locally in `.private/recovery/form-build4-2026-10-02/FormPersonal.app`, with a metadata/hash manifest beside it. It contains the app binary, not a copy of the phone's health database or Keychain. The old signing profile expires October9,2026 at21:34:56UTC; after that, rebuild the tagged source with the same team, bundle and local public OAuth configuration.

To roll back while the old signature is valid:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun devicectl device install app --device YOUR_DEVICE_UDID \
.private/recovery/form-build4-2026-10-02/FormPersonal.app
```

Install over the existing app; do not delete the app first, since deletion removes its local data. Keep `com.amal.form`, the existing team and Google client. The legacy `health-cache.json` is preserved byte-for-byte while BetterFit writes `health-cache-v2.json` and `saved-dashboard.json`. The previous app can load the legacy file and refresh normally. Explicit disconnect removes both generations, as it should.

For a later rebuild, make a separate local checkout from `form-build4-stable` (do not reset the current work), copy the ignored `iOS/Configuration/Local.xcconfig` public configuration into that checkout, and build its **Form Personal** scheme for the same phone. No OAuth credentials or health files belong in Git. The new AppGroup-backed widgets disappear when the old main-app-only build replaces it; re-add them after returning to BetterFit.
