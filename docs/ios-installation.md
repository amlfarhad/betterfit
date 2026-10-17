# Install BetterFit on iPhone

BetterFit is a native SwiftUI app for iOS17 or later. Open `iOS/Form.xcodeproj`. Both the **Form** and retained **Form Personal** schemes now build the full app, including Home and Lock Screen widgets, using optimized Release for Run. The old scheme name is an alias to avoid disrupting the existing Xcode selection. Internal bundle IDs, OAuth callback and Keychain identity stay unchanged.

The existing free Personal Team successfully provisioned `com.amal.form`, `com.amal.form.widgets` and their shared group `group.com.amal.form`. No Apple Developer Program purchase is needed for this verified setup. See [actual signing evidence](research/2026-10-02-widget-signing.md).

The unconfigured app supports importing an engine-input JSON snapshot and explicitly choosing sample data. Google sign-in becomes available after configuring an **iOS** OAuth client. Desktop OAuth credentials and existing Desktop tokens cannot be used in the phone app.

## Xcode and signing

1. Finish installing full Xcode, open it once, and install its iOS platform support. Command Line Tools alone do not include the iPhone SDK or simulator. In Xcode → Settings → Locations, select the new Xcode command-line tools.
2. Open `iOS/Form.xcodeproj`. Select **Form** (or the retained **Form Personal** alias); a simulator is the quickest first build and does not need device provisioning.
3. To run on your phone, add your Apple account in Xcode Settings, connect the phone, enable Developer Mode if iOS requests it, and select the phone as the run destination.
4. In **Signing & Capabilities**, select your existing **Personal Team** for the **Form** and **FormWidgets** targets and leave automatic signing enabled. Both share the registered App Group.
5. The default app bundle ID is `com.amal.form`. If Xcode cannot provision that identifier for your account, set a unique one in the local configuration below. The iOS Google client must match the final bundle ID.
6. Build and run. Resolve any account/device provisioning prompts in Xcode. Physical-device signing has to succeed for your account and device; an unsigned simulator build does not verify it.

Both schemes use the optimized **Release** configuration for Run. For everyday use, launch from the phone outside an attached Xcode debug session. Tests and analysis retain their Debug configuration.

Apple permits on-device testing with a free Personal Team, but its provisioning profiles expire after seven days. Rebuild and reinstall through Xcode after expiry; keep the same bundle ID and team for routine reinstalls. This path does not require an Apple Developer Program subscription. [Apple's Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)

To add Lock Screen widgets, touch and hold the Lock Screen → Customize → Lock Screen → Add Widgets → **BetterFit**. Choose circular Recovery, Activity or Sleep, or the rectangular summary. Home Screen small/medium widgets are also included. iOS requires the user to choose placement; installing an extension cannot place it automatically. Activity's ring compares with your usual completed day after enough history, not a target. WidgetKit controls refresh timing and shows saved data when stale.

Configuration values live in `iOS/Configuration/Base.xcconfig`. An optional `iOS/Configuration/Local.xcconfig` overrides them and is ignored by Git. For signing or App Group overrides without OAuth, create that local file with only the needed public identifiers:

```xcconfig
// Use your registered identifiers and ten-character Apple Team ID.
FORM_BUNDLE_ID = com.yourteam.form
FORM_WIDGET_BUNDLE_ID = com.yourteam.form.widgets
FORM_APP_GROUP = group.com.yourteam.form
DEVELOPMENT_TEAM = YOURTEAMID
```

Choose actual registered values before using that example. With **Form Personal**, only `FORM_BUNDLE_ID` and the optional `DEVELOPMENT_TEAM` override are needed; widget/group values are ignored by that target. Leave the OAuth values absent until you have the iOS client; an empty client ID disables sign-in while import and sample data remain available.

## Configure Google sign-in

In your Google Cloud project, create an OAuth client whose application type is **iOS**, with the app's exact bundle ID. Configure the consent screen and authorized testing account as required by your existing Google Health API project. Download that iOS client's configuration. Google's iOS flow supplies an iOS plist; the helper also accepts JSON with explicit iOS bundle identity. See [Google's iOS client setup](https://developers.google.com/identity/sign-in/ios/start-integrating) and [native-app OAuth configuration](https://developers.google.com/identity/protocols/oauth2/native-app).

From the repository root, pass the downloaded file yourself:

```sh
python3 scripts/configure_ios.py /path/to/downloaded-ios-client.plist
```

Or, for an iOS JSON download and custom registered identifiers:

```sh
python3 scripts/configure_ios.py /path/to/downloaded-ios-client.json \
  --bundle-id com.yourteam.form \
  --app-group group.com.yourteam.form \
  --team-id YOURTEAMID
```

The helper writes `iOS/Configuration/Local.xcconfig` with the public client ID, its reversed callback scheme, bundle IDs, App Group, and optional signing team. Both schemes use the OAuth configuration; **Form Personal** ignores the App Group setting. The helper does not copy the downloaded file into the app or write tokens. Rerunning it replaces that local config, so include any custom signing/group arguments again. Never pass the existing Desktop client JSON, token JSON, or a service-account key.

Accepted iOS plist fields are `CLIENT_ID`, `BUNDLE_ID`, and optional `REVERSED_CLIENT_ID`. JSON may contain those fields directly, or an `installed`/`ios` object with `client_id` and `ios_bundle_id` or `ios_info.bundle_id`. The bundle must match `--bundle-id`. An untyped `installed` JSON without iOS bundle metadata is rejected, as are files containing secrets or tokens. If a downloaded JSON lacks that metadata, use the iOS client's plist download; do not alter Desktop credentials to bypass validation.

Rebuild after changing config. The app reads `FORM_GOOGLE_CLIENT_ID` and `FORM_GOOGLE_REDIRECT_SCHEME` from its built Info.plist. The reversed scheme is registered for OAuth callbacks; `form://metric/recovery`, `form://metric/strain`, and `form://metric/sleep` open metric details. The extension has no OAuth configuration or token access.

For an already-signed personal build and an already-paired phone, `scripts/install_on_reconnect.py --help` describes a bounded, one-time reconnect installer. It validates the configured bundle, callback, signing team, profile expiry, device inclusion and code signature before installing. It installs once, then opens Form when the phone allows it. It does not complete Google consent, change device security settings, or survive a Mac restart. Check any existing installer process before starting another.

## Refresh and widget behavior

The app refreshes on foreground/manual actions, with its own eligibility interval while visible. It also submits a `BGAppRefreshTaskRequest` when it enters the background, with an earliest opportunity 30 minutes later. This is best effort: iOS chooses whether and when to run and may defer it for power, usage, network, or user settings. The registered identifier is `com.amal.form.refresh`. See [Apple's SwiftUI background tasks](https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:)).

In the **Form** build, widgets only read `widget-snapshot.json` from the configured App Group. The app writes it atomically and requests widget reloads. The widget also requests a timeline opportunity after 30 minutes, which the system may defer. It never calls Google or computes new health scores. Missing/calibrating scores appear as dashes. The score date is shown separately from the saved snapshot age; imported and synthetic data carry explicit source labels. The views are marked privacy-sensitive for system redaction. Disconnecting must clear the app's shared snapshot as well as its private session data. **Form Personal** neither embeds the extension nor reads/writes the App Group snapshot.

## Verification

Checks available without full Xcode:

```sh
python3 -m unittest discover -s iOS/Tests -p 'test_*.py' -v
plutil -lint iOS/Form.xcodeproj/project.pbxproj \
  iOS/Form/Info.plist iOS/Form/Form.entitlements \
  iOS/FormWidgets/Info.plist iOS/FormWidgets/FormWidgets.entitlements
swiftc -module-cache-path /tmp/form-widget-module-cache \
  iOS/FormWidgets/WidgetSnapshot.swift iOS/Tests/WidgetSnapshotTests.swift \
  -o /tmp/form-widget-tests
/tmp/form-widget-tests
```

After installing full Xcode:

```sh
xcodebuild -list -project iOS/Form.xcodeproj
xcodebuild -project iOS/Form.xcodeproj -scheme Form \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iOS/Form.xcodeproj -scheme 'Form Personal' \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-personal CODE_SIGNING_ALLOWED=NO build
```

Then verify on a phone: Google sign-in returns to Form; foreground/manual sync retains the last good data on failure; file import works; widgets match the latest snapshot and open their metric; disconnect removes widget values. Background delivery is governed by iOS and cannot be guaranteed from a successful build.

The project/plists, configuration boundary tests, snapshot decoder tests, and widget Swift 6 typechecking were checked during implementation. Full Xcode 27 subsequently became available: **Form** with its widget and **Form Personal** both built successfully for iOS Simulator. The built Personal app was checked for an empty App Group and no embedded extension. On 2026-10-02, physical-device signing, installation and launch succeeded; the user confirmed Google consent and the live dashboard. An optimized Personal build was then installed and launched. See [performance validation](validation/2026-10-02-performance.md). On-device background and widget behavior remain unverified.

The checked-in project can be regenerated after structural changes with `python3 scripts/generate_xcode_project.py`. That operation rewrites the project and both shared schemes, so keep custom signing/config values in the ignored local xcconfig rather than editing generated project settings. Debug builds compile the active architecture so the app and local Swift package agree for the selected simulator; Release builds retain all supported architectures.
