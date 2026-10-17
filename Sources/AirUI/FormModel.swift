import Foundation
import SwiftUI
import Observation
import FitbitMetrics
import AirSync
import AirAuth
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum FormDataMode: String, Codable, Sendable { case disconnected, connected, imported, demo }
public enum FormTab: String, CaseIterable { case today = "Today", trends = "Trends", age = "Age" }

/// A narrow boundary keeps source transitions independently verifiable without
/// a real Google account, while production uses the native auth and sync actors.
struct FormAccountOperations {
    let signIn: @MainActor () async throws -> Void
    let hasCredentials: @MainActor () async throws -> Bool
    let load: @MainActor (Double) async throws -> SyncSnapshot?
    let refresh: @MainActor (Double, Bool) async throws -> SyncSnapshot
    let clear: @MainActor () async throws -> Void
    let disconnect: @MainActor () async throws -> Void
}

public enum FormMetric: String, CaseIterable, Identifiable {
    case recovery, strain, sleep, hrv, restingHR, steps, oxygen, breathing, temperature
    public var id: String { rawValue }
    var title: String {
        switch self { case .recovery: "Recovery"; case .strain: "Activity"; case .sleep: "Sleep"
        case .hrv: "Heart rate variability"; case .restingHR: "Resting heart rate"; case .steps: "Steps"
        case .oxygen: "Blood oxygen"; case .breathing: "Breathing rate"; case .temperature: "Skin temperature" }
    }
    var shortTitle: String { switch self { case .hrv: "HRV"; case .restingHR: "Resting HR"
        case .oxygen: "SpO₂"; case .breathing: "Breathing"; case .temperature: "Skin temp"; default: title } }
    var symbol: String {
        switch self { case .recovery: "arrow.triangle.2.circlepath"; case .strain: "waveform.path"
        case .sleep: "moon.fill"; case .hrv: "waveform.path.ecg"; case .restingHR: "heart"; case .steps: "figure.walk"
        case .oxygen: "drop"; case .breathing: "lungs"; case .temperature: "thermometer.medium" }
    }
    var tint: Color { switch self { case .recovery, .hrv: FormPalette.recovery
        case .strain, .steps, .oxygen, .breathing: FormPalette.strain
        case .sleep: FormPalette.sleep; case .restingHR, .temperature: FormPalette.age } }
    var unit: String { switch self { case .strain: "min"; case .hrv: "ms"; case .restingHR: "bpm"
        case .steps: "steps"; case .oxygen: "%"; case .breathing: "br/min"; case .temperature: "°C"; default: "/ 100" } }
    var digits: Int { [.oxygen, .breathing, .temperature].contains(self) ? 1 : 0 }
    var vitalKind: VitalKind? { switch self { case .hrv: .hrv; case .restingHR: .restingHeartRate
        case .oxygen: .oxygenSaturation; case .breathing: .respiratoryRate; case .temperature: .skinTemperature; default: nil } }
}

@MainActor @Observable
public final class FormModel {
    public var tab: FormTab = .today
    public var selectedDate = ""
    public var selectedMetric: FormMetric? = nil
    public var showConnection = false
    public var trendMetric: FormMetric = .recovery
    public var trendDays = 7
    public private(set) var input: InputBundle?
    public private(set) var scores: ScoreBundle?
    public private(set) var mode: FormDataMode = .disconnected
    public private(set) var isRefreshing = false
    public private(set) var lastChecked: Date?
    public private(set) var lastMeasured: Date?
    public private(set) var lastSuccessfulSync: Date?
    public private(set) var syncError: String?
    public private(set) var needsReauthorization = false
    public private(set) var configurationAvailable = false
    public var sleepTarget: Double = 480
    public var notice: String?
    @ObservationIgnored var accountOperations: FormAccountOperations?
    private var didStart = false
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    private var isRestoringSource = false
    @ObservationIgnored private let preview: Bool
    @ObservationIgnored private let storage: URL
    @ObservationIgnored private var sourceGeneration: UInt64 = 0
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var signInTask: Task<Void, any Error>?
    @ObservationIgnored private var refreshTask: Task<SyncSnapshot, any Error>?
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var isRemovingData = false
    @ObservationIgnored private var insightCache: [String: DailyInsight] = [:]
    @ObservationIgnored private var sessionEvents: [String] = []
    @ObservationIgnored private let sessionDiagnosticsEnabled = ProcessInfo.processInfo.arguments.contains("--session-diagnostics")

    // Explicit developer launch only: bounded status labels, never readings or tokens.
    private func recordSession(_ event: String) {
        guard !preview, sessionDiagnosticsEnabled else { return }
        sessionEvents.append(event)
        sessionEvents = Array(sessionEvents.suffix(12))
        if let data = try? JSONEncoder().encode(sessionEvents) {
            try? writePrivate(data, name: "session-diagnostics.json")
        }
    }

    var isLoadingSavedSource: Bool { !preview && input == nil && (!didStart || isRestoringSource) }
    var showsWelcome: Bool { input == nil && !isLoadingSavedSource && mode != .connected }

    public init(input: InputBundle? = nil, mode: FormDataMode = .imported, preview: Bool = false,
                storageDirectory: URL? = nil) {
        self.preview = preview
        storage = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Form", isDirectory: true)
        if let input, let scores = try? MetricsEngine.evaluate(input) {
            self.input = input; self.scores = scores; self.mode = mode
            selectedDate = input.asOfDate; sleepTarget = input.sleepTargetMinutes
        }
        if !preview, let config = try? OAuthConfiguration.load() {
            let coordinator = GoogleSignInCoordinator(configuration: config)
            configurationAvailable = true
            let provider = coordinator.tokenProvider
            let sync = NativeHealthSync(cacheURL: storage.appendingPathComponent("health-cache-v2.json"),
                                       legacyCacheURL: storage.appendingPathComponent("health-cache.json"),
                                       accessToken: { try await provider.accessToken() })
            accountOperations = FormAccountOperations(
                signIn: { try await coordinator.signIn() },
                hasCredentials: { try await provider.hasCredentials() },
                load: { try await sync.load(timeZone: .current, sleepTargetMinutes: $0) },
                refresh: { try await sync.refresh(timeZone: .current, sleepTargetMinutes: $0, force: $1) },
                clear: { try await sync.clear() },
                disconnect: { try await coordinator.disconnect() })
        }
        if !preview, !sessionDiagnosticsEnabled { try? removeStoredFile("session-diagnostics.json") }
    }

    public func startup() async {
        guard !preview, !isRemovingData, !isConnecting else { return }
        if let startupTask { await startupTask.value; return }
        guard !didStart else { return }
        didStart = true
        isRestoringSource = true
        let task = Task { await restoreSelectedSource() }
        startupTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        startupTask = nil
    }

    private func restoreSelectedSource() async {
        defer { isRestoringSource = false }
        recordSession("restore_started")
        let generation = sourceGeneration
        if input == nil {
            do {
                let preferences = try loadPreferences()
                if let preferences { sleepTarget = preferences.sleepTarget; mode = preferences.mode }
                else if FileManager.default.fileExists(atPath: storage.appendingPathComponent("imported-snapshot.json").path) {
                    mode = .imported
                }
                switch mode {
                case .demo: try installDemo(persist: false)
                case .imported:
                    let data = try Data(contentsOf: storage.appendingPathComponent("imported-snapshot.json"))
                    try installCanonical(data, persist: false, targetOverride: preferences?.sleepTarget)
                case .connected, .disconnected: break
                }
            } catch {
                recordSession("preferences_or_import_unavailable")
                mode = .disconnected
                syncError = "Saved data or preferences could not be read. Import your snapshot again or reconnect."
            }
        }
        // An imported snapshot or demo is a deliberate source selection, even
        // when an existing Google credential is still available.
        if mode == .connected {
            recordSession("saved_connected")
            restoreDashboard()
            do {
                if let cached = try await accountOperations?.load(sleepTarget) {
                    guard generation == sourceGeneration, mode == .connected else { return }
                    apply(cached)
                    recordSession("cache_restored")
                } else { recordSession("cache_absent") }
            } catch { recordSession("cache_load_failed_" + String(describing: type(of: error))) }
            guard generation == sourceGeneration, mode == .connected else { return }
            isRestoringSource = false
            await refresh(force: false)
        }
    }

    public func connect() async {
        guard !preview, !isRemovingData, !isRestoringSource else { return }
        guard let account = accountOperations else {
            notice = "Google sign-in needs the iOS client configuration. You can import your account snapshot now; setup instructions are included with the Xcode project."
            return
        }
        guard !isRefreshing else { return }
        invalidateOperations()
        let generation = sourceGeneration, id = UUID()
        operationID = id; isRefreshing = true; isConnecting = true; syncError = nil
        defer { finishOperation(id) }
        var authorized = false
        var previousPreferences: Data?
        var wroteFence = false
        do {
            try Task.checkCancellation()
            let preferencesURL = storage.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: preferencesURL.path) {
                previousPreferences = try Data(contentsOf: preferencesURL)
            }
            // Do not load an old account cache after a process interruption
            // between Google's credential commit and our local cache clear.
            // Ordinary cancellation restores these exact preferences below.
            try writePrivate(JSONEncoder().encode(FormPreferences(mode: .disconnected, sleepTarget: sleepTarget)), name: "preferences.json")
            wroteFence = true
            let task = Task { try await account.signIn() }
            signInTask = task
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            authorized = true
            guard matchesOperation(id, generation: generation) else { return }
            // Authorization succeeded. Retire the old displayed source before
            // any suspension; no request may use new tokens with the old cache.
            clearDisplayedData(mode: .disconnected)
            try removeWidget()
            try removeStoredFile("saved-dashboard.json")
            try await account.clear()
            guard matchesOperation(id, generation: generation) else { return }
            try removeStoredFile("imported-snapshot.json")
            try Task.checkCancellation()
            mode = .connected
            try savePreferences()
            finishOperation(id)
            await refresh(force: true)
        } catch {
            // Cleanup must also run when the caller was cancelled immediately
            // after credentials were committed. A newer disconnect owns itself.
            guard matchesOperation(id, generation: generation) else { return }
            if authorized {
                clearDisplayedData(mode: .disconnected)
                sleepTarget = 480
                try? savePreferences()
                try? removeStoredFile("imported-snapshot.json")
                try? removeStoredFile("health-cache.json")
                try? removeStoredFile("health-cache-v2.json")
                try? removeStoredFile("saved-dashboard.json")
                try? removeWidget()
                try? await account.disconnect()
                guard matchesOperation(id, generation: generation) else { return }
                syncError = "The previous account data could not be cleared. Connect again after local storage is available."
            } else {
                do {
                    if wroteFence {
                        if let previousPreferences { try writePrivate(previousPreferences, name: "preferences.json") }
                        else { try removeStoredFile("preferences.json") }
                    }
                    if !(error is CancellationError) { syncError = Self.safeError(error) }
                } catch {
                    syncError = "Sign-in did not complete, and the previous source setting could not be restored. Your offline cache is preserved."
                }
            }
        }
    }

    public func refresh(force: Bool = true) async {
        // Foreground activation may request refresh while a cold launch is
        // still loading its selected cache. Restoration must finish first.
        if isRestoringSource, let startupTask { await startupTask.value }
        guard !preview, !isRefreshing, !isRemovingData else { return }
        guard mode == .connected else {
            if force {
                notice = mode == .demo ? "You’re exploring sample data. Connect Google Health or import your snapshot to see your own metrics."
                    : mode == .imported ? "This is a saved snapshot. Connect Google Health for automatic updates, or import a newer snapshot."
                    : "Connect Google Health or import a snapshot to see your metrics."
            }
            return
        }
        guard let account = accountOperations else {
            notice = "Google sign-in needs the iOS client configuration before readings can refresh."
            return
        }
        let generation = sourceGeneration, id = UUID()
        operationID = id
        isRefreshing = true; syncError = nil
        defer { finishOperation(id) }
        do {
            let credentials = try await account.hasCredentials()
            recordSession(credentials ? "credentials_available" : "credentials_absent")
            guard currentOperation(id, generation: generation), mode == .connected else { return }
            guard credentials else {
                needsReauthorization = true
                notice = "Connect Google Health again to resume automatic updates. Your saved readings are still available."
                return
            }
            needsReauthorization = false
            let target = sleepTarget
            let task = Task { try await account.refresh(target, force) }
            refreshTask = task
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard currentOperation(id, generation: generation), mode == .connected else { return }
            apply(result)
            recordSession("refresh_applied")
        }
        catch is CancellationError { }
        catch {
            guard currentOperation(id, generation: generation), mode == .connected else { return }
            if let authError = error as? OAuthError, authError == .reauthorizationRequired || authError == .notSignedIn {
                needsReauthorization = true
            }
            if let apiError = error as? SyncError, apiError == .http(401) || apiError == .http(403) {
                needsReauthorization = true
            }
            syncError = Self.safeError(error); lastChecked = Date()
            recordSession("refresh_failed_" + String(describing: type(of: error)))
        }
    }

    private func apply(_ snapshot: SyncSnapshot) {
        // AirSync has already validated and calculated these scores on its
        // actor. Publishing a refresh should not repeat that work on the UI.
        let wasLatest = selectedDate.isEmpty || selectedDate == input?.asOfDate
        insightCache.removeAll(keepingCapacity: true)
        input = snapshot.input; scores = snapshot.scores; mode = .connected
        if wasLatest { selectedDate = snapshot.input.asOfDate }
        lastChecked = snapshot.freshness.checkedAt
        lastMeasured = snapshot.freshness.lastMeasurementAt
        lastSuccessfulSync = snapshot.freshness.lastSuccessfulSync
        syncError = Self.refreshWarning(snapshot.freshness.failures)
        if sessionDiagnosticsEnabled {
            let failures = Set(snapshot.freshness.failures.map { $0.metric + "_" + $0.code }).sorted()
            if failures.isEmpty { recordSession("sync_no_failed_streams") }
            for failure in failures.prefix(8) { recordSession("sync_failure_" + failure) }
            if let latest = snapshot.scores.days.first(where: { $0.date == snapshot.input.asOfDate }) {
                let allowed: Set<String> = ["missingSleep", "missingRMSSD", "missingRestingHeartRate", "insufficientBaseline", "inputIssues", "invalid_sleep", "invalid_sleep_stages", "multiple_main_sleeps"]
                for (name, score) in [("sleep", latest.sleep), ("recovery", latest.recovery)] {
                    let reasons = score.reasons.filter { allowed.contains($0) }.joined(separator: "_")
                    recordSession(name + "_" + score.status.rawValue + (reasons.isEmpty ? "" : "_" + reasons))
                }
            }
        }
        saveDashboard()
        writeWidget()
    }

    public func exploreDemo() {
        guard !isRemovingData, !isConnecting else { return }
        do {
            invalidateOperations()
            try installDemo(persist: !preview)
            showConnection = false; tab = .today
        } catch { syncError = "The sample selection could not be saved. Local storage may be unavailable." }
    }

    private func installDemo(persist: Bool) throws {
        var sample = FormDemo.input()
        sample.sleepTargetMinutes = sleepTarget
        let result = try MetricsEngine.evaluate(sample)
        if persist {
            try writePrivate(JSONEncoder().encode(FormPreferences(mode: .demo, sleepTarget: sleepTarget)), name: "preferences.json")
        }
        insightCache.removeAll(keepingCapacity: true)
        scores = result; input = sample
        mode = .demo; selectedDate = sample.asOfDate
        lastChecked = nil; lastMeasured = nil; lastSuccessfulSync = nil; syncError = nil; notice = nil
        writeWidget()
    }

    public func importCanonical(_ data: Data) {
        guard !isRemovingData, !isConnecting else { return }
        do { try installCanonical(data, persist: !preview); showConnection = false; notice = nil }
        catch is SnapshotPersistenceError { syncError = "The snapshot could not be saved. Your previous data is still shown. Check local storage and try again." }
        catch { syncError = "This file is not a valid BetterFit input snapshot. Export engine-input.json from the account tool and try again." }
    }

    private func installCanonical(_ data: Data, persist: Bool, targetOverride: Double? = nil) throws {
        guard data.count < 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
        var bundle = try JSONDecoder().decode(InputBundle.self, from: data)
        if let targetOverride { bundle.sleepTargetMinutes = targetOverride }
        let result = try MetricsEngine.evaluate(bundle)
        if persist {
            try persistCanonical(data, target: bundle.sleepTargetMinutes)
        }
        if persist || preview { invalidateOperations() }
        insightCache.removeAll(keepingCapacity: true)
        input = bundle; scores = result; mode = .imported; selectedDate = bundle.asOfDate
        sleepTarget = bundle.sleepTargetMinutes; lastChecked = nil
        lastSuccessfulSync = nil; lastMeasured = nil; syncError = nil
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let provenance = root["provenance"] as? [String: Any],
           let freshness = provenance["freshness"] as? [String: Any],
           let hr = freshness["heart-rate"] as? [String: Any], let stamp = hr["latestMeasurementAt"] as? String {
            lastMeasured = Self.isoDate(stamp)
        }
        writeWidget()
    }

    public func updateSleepTarget(_ value: Double) {
        guard !isConnecting, !isRemovingData, value.isFinite, (360...720).contains(value), var copy = input else { return }
        copy.sleepTargetMinutes = value
        do {
            let result = try MetricsEngine.evaluate(copy)
            if !preview {
                try writePrivate(JSONEncoder().encode(FormPreferences(mode: mode, sleepTarget: value)), name: "preferences.json")
            }
            invalidateOperations()
            insightCache.removeAll(keepingCapacity: true)
            scores = result; input = copy; sleepTarget = value
            saveDashboard()
            writeWidget()
        }
        catch { syncError = "This sleep target could not be saved. Local storage may be unavailable." }
    }

    public func disconnect() async {
        guard !isRemovingData else { return }
        isRemovingData = true
        defer { isRemovingData = false }
        invalidateOperations()
        clearDisplayedData(mode: .disconnected)
        sleepTarget = 480
        showConnection = false; tab = .today
        guard !preview else { return }
        var failed = false
        // Persist the source fence before suspension: a killed process must not
        // restore this account while asynchronous credential cleanup is pending.
        do { try savePreferences() } catch { failed = true }
        do { try removeStoredFile("saved-dashboard.json") } catch { failed = true }
        do { try await accountOperations?.disconnect() } catch { failed = true }
        do { try await accountOperations?.clear() } catch { failed = true }
        for name in ["imported-snapshot.json", "health-cache.json", "health-cache-v2.json", "saved-dashboard.json", "preferences.json"] {
            do { try removeStoredFile(name) } catch { failed = true }
        }
        do { try removeWidget() } catch { failed = true }
        if failed { syncError = "Local data could not be fully removed. Unlock the device and try again." }
    }

    private func currentOperation(_ id: UUID, generation: UInt64) -> Bool {
        matchesOperation(id, generation: generation) && !Task.isCancelled
    }

    private func matchesOperation(_ id: UUID, generation: UInt64) -> Bool {
        operationID == id && sourceGeneration == generation
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; signInTask = nil; refreshTask = nil; isRefreshing = false; isConnecting = false
    }

    private func invalidateOperations() {
        sourceGeneration &+= 1
        startupTask?.cancel()
        signInTask?.cancel(); refreshTask?.cancel()
        signInTask = nil; refreshTask = nil; operationID = nil; isRefreshing = false; isConnecting = false
    }

    private func clearDisplayedData(mode: FormDataMode) {
        insightCache.removeAll(keepingCapacity: true)
        input = nil; scores = nil; selectedDate = ""; selectedMetric = nil; self.mode = mode
        needsReauthorization = false
        lastChecked = nil; lastMeasured = nil; lastSuccessfulSync = nil; syncError = nil; notice = nil
    }

    private func loadPreferences() throws -> FormPreferences? {
        let url = storage.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 65_536 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(FormPreferences.self, from: data)
        guard value.sleepTarget.isFinite, value.sleepTarget > 0, value.sleepTarget <= 1440 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }

    private func savePreferences() throws {
        guard !preview else { return }
        try writePrivate(JSONEncoder().encode(FormPreferences(mode: mode, sleepTarget: sleepTarget)), name: "preferences.json")
    }

    private func persistCanonical(_ data: Data, target: Double) throws {
        do {
            func existing(_ name: String) throws -> Data? {
                let url = storage.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            }
            let oldSnapshot = try existing("imported-snapshot.json")
            let oldPreferences = try existing("preferences.json")
            do {
                try writePrivate(data, name: "imported-snapshot.json")
                try writePrivate(JSONEncoder().encode(FormPreferences(mode: .imported, sleepTarget: target)), name: "preferences.json")
            } catch {
                // Keep the two persisted files consistent if the second write
                // fails. In-memory data changes only after both writes succeed.
                if let oldSnapshot { try? writePrivate(oldSnapshot, name: "imported-snapshot.json") }
                else { try? removeStoredFile("imported-snapshot.json") }
                if let oldPreferences { try? writePrivate(oldPreferences, name: "preferences.json") }
                else { try? removeStoredFile("preferences.json") }
                throw error
            }
        } catch { throw SnapshotPersistenceError.failed }
    }

    private func writePrivate(_ data: Data, name: String) throws {
        guard !preview else { return }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let url = storage.appendingPathComponent(name)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    private func removeStoredFile(_ name: String) throws {
        let url = storage.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func open(_ url: URL) {
        guard url.scheme == "form" else { return }
        if url.host == "age" { tab = .age }
        else if url.host == "metric", let metric = FormMetric(rawValue: url.lastPathComponent) {
            if let latest = input?.asOfDate { selectedDate = latest }
            selectedMetric = metric
        } else { selectedMetric = nil; showConnection = false; tab = .today }
    }

    var currentInsight: DailyInsight? { insight(for: selectedDate) }
    func insight(for date: String) -> DailyInsight? {
        guard let input, let scores else { return nil }
        if let cached = insightCache[date] { return cached }
        let result = BetterFitInsights.evaluate(input: input, scores: scores, date: date)
        if let result { insightCache[date] = result }
        return result
    }
    private func restoreDashboard() {
        guard input == nil else { return }
        let url = storage.appendingPathComponent("saved-dashboard.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= SavedDashboard.maximumBytes,
              let data = try? Data(contentsOf: url),
              let restored = try? SavedDashboard.restore(data, timeZone: .current, target: sleepTarget) else { return }
        input = restored.record.input; scores = restored.scores
        selectedDate = restored.record.input.asOfDate
        lastChecked = restored.record.checkedAt; lastMeasured = restored.record.measuredAt
        lastSuccessfulSync = restored.record.successfulAt
        insightCache.removeAll(keepingCapacity: true)
        recordSession("dashboard_restored")
    }
    private func saveDashboard() {
        guard !preview, mode == .connected, let input else { return }
        let record = SavedDashboard(input: input, timeZone: TimeZone.current.identifier,
            checkedAt: lastChecked, measuredAt: lastMeasured, successfulAt: lastSuccessfulSync)
        if let data = try? JSONEncoder().encode(record), data.count <= SavedDashboard.maximumBytes {
            try? writePrivate(data, name: "saved-dashboard.json")
        }
    }

    var currentDay: DailyScores? { scores?.days.first { $0.date == selectedDate } }
    var currentInput: DailyInput? { input?.days.first { $0.date == selectedDate } }
    func score(_ metric: FormMetric, on day: DailyScores? = nil) -> Score? {
        guard let d = day ?? currentDay else { return nil }
        switch metric { case .recovery: return d.recovery; case .strain: return d.strain; case .sleep: return d.sleep; default: return nil }
    }
    func value(_ metric: FormMetric, date: String) -> Double? {
        let d = scores?.days.first { $0.date == date }
        let raw = input?.days.first { $0.date == date }
        if let kind = metric.vitalKind {
            return insight(for: date)?.vitals.first { $0.kind == kind }?.value
        }
        switch metric { case .recovery: return d?.recovery.value; case .strain: return insight(for: date)?.activity.elevatedMinutes
        case .sleep: return d?.sleep.value; case .hrv: return raw?.rmssdMs
        case .restingHR: return raw?.restingHeartRate; case .steps: return raw.map { $0.issues.contains("invalid_steps") || $0.issues.contains("overlapping_steps") ? nil : $0.steps } ?? nil
        case .oxygen: return raw?.oxygenSaturationPercent; case .breathing: return raw?.respiratoryRateBrpm
        case .temperature: return raw?.skinTemperatureCelsius }
    }
    var baselineNights: Int { Int(currentDay?.recovery.components["baselineNights"] ?? 0) }
    var todayKey: String { Self.dateKey(Date()) }
    var modeLabel: String { switch mode { case .connected: "Google Health"; case .imported: "Saved snapshot"; case .demo: "Sample data"; case .disconnected: "Not connected" } }
    var measurementCaption: String {
        if mode == .demo { return "SYNTHETIC DEMO" }
        if let lastMeasured { return "MEASURED " + Self.relative(lastMeasured).uppercased() }
        return mode == .imported ? "IMPORTED DATA" : "AWAITING READINGS"
    }
    var dates: [String] {
        guard let key = input?.asOfDate, let end = Self.calendarDate(key) else { return [] }
        return (0..<7).reversed().compactMap { offset in Calendar.current.date(byAdding: .day, value: -offset, to: end).map(Self.dateKey) }
    }
    func history(_ metric: FormMetric, count: Int) -> [ChartPoint] {
        guard let end = Self.calendarDate(input?.asOfDate ?? todayKey) else { return [] }
        return (0..<count).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let key = Self.dateKey(date)
            return ChartPoint(date: key, value: value(metric, date: key))
        }
    }
    // Main-actor confined. Constructing formatters for every label in every
    // chart-drag frame is much more expensive than formatting with a reused one.
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static func dateFormatter(_ format: String, fixedLocale: Bool = false) -> DateFormatter {
        let locale = fixedLocale ? Locale(identifier: "en_US_POSIX") : Locale.current
        let zone = TimeZone.current
        let key = "\(locale.identifier)|\(zone.identifier)|\(format)"
        if let cached = dateFormatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = zone
        if fixedLocale { formatter.calendar = Calendar(identifier: .gregorian) }
        formatter.dateFormat = format
        if dateFormatters.count >= 32 { dateFormatters.removeAll(keepingCapacity: true) }
        dateFormatters[key] = formatter
        return formatter
    }
    static func dateKey(_ date: Date) -> String {
        dateFormatter("yyyy-MM-dd", fixedLocale: true).string(from: date)
    }
    static func calendarDate(_ key: String) -> Date? {
        dateFormatter("yyyy-MM-dd", fixedLocale: true).date(from: key)
    }
    static func dateLabel(_ key: String, format: String) -> String {
        guard let date = calendarDate(key) else { return key }
        return dateFormatter(format).string(from: date)
    }
    static func isoDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f.localizedString(for: date, relativeTo: Date())
    }
    static func refreshWarning(_ failures: [MetricFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        let labels = ["sleep": "Sleep", "steps": "Steps", "heart-rate": "Heart rate",
            "daily-heart-rate-variability": "HRV", "daily-resting-heart-rate": "Resting heart rate",
            "daily-oxygen-saturation": "Blood oxygen", "daily-respiratory-rate": "Breathing rate",
            "daily-sleep-temperature-derivations": "Skin temperature", "profile": "Profile"]
        let names = Set(failures.map { labels[$0.metric] ?? "Some readings" }).sorted().joined(separator: ", ")
        return names + " couldn’t refresh. Any saved readings are still shown."
    }

    static func safeError(_ error: Error) -> String {
        // Authentication/network implementations supply scrubbed descriptions, never response bodies.
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return "Google Health could not refresh. Your saved readings are still available; try again shortly."
    }
    private func writeWidget() {
        guard !preview else { return }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") as? String, !group.isEmpty else {
            recordSession("widget_group_unconfigured"); return
        }
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            recordSession("widget_container_unavailable"); return
        }
        let day = scores?.days.first { $0.date == input?.asOfDate }
        let activity = input.flatMap { insight(for: $0.asOfDate)?.activity }
        let record = WidgetRecord(generatedAt: ISO8601DateFormatter().string(from: Date()),
            measuredAt: lastMeasured.map { ISO8601DateFormatter().string(from: $0) }, date: input?.asOfDate ?? "", mode: mode.rawValue,
            recovery: day?.recovery.value, recoveryStatus: day?.recovery.status.rawValue ?? "unavailable",
            strain: day?.strain.value, strainStatus: day?.strain.status.rawValue ?? "unavailable",
            sleep: day?.sleep.value, sleepStatus: day?.sleep.status.rawValue ?? "unavailable",
            age: scores?.biologicalAge.score.value, ageStatus: scores?.biologicalAge.score.status.rawValue ?? "unavailable",
            ageCollectedDays: scores?.biologicalAge.collection.eligibleDays ?? 0,
            activityMinutes: activity?.elevatedMinutes, activityBaselineMinutes: activity?.baseline?.median,
            activityCoverage: activity?.coverageFraction)
        do {
            let data = try JSONEncoder().encode(record)
            #if os(iOS)
            try data.write(to: directory.appendingPathComponent("widget-snapshot.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: directory.appendingPathComponent("widget-snapshot.json"), options: .atomic)
            #endif
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            recordSession("widget_snapshot_saved")
        } catch {
            // Status-only diagnostics never contain readings, tokens or URLs.
            recordSession("widget_snapshot_failed_" + String((error as NSError).code))
        }
    }

    private func removeWidget() throws {
        guard !preview,
              let group = Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") as? String,
              !group.isEmpty, let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let url = directory.appendingPathComponent("widget-snapshot.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

private struct FormPreferences: Codable { let mode: FormDataMode; let sleepTarget: Double }
private enum SnapshotPersistenceError: Error { case failed }
struct ChartPoint: Identifiable { let date: String; let value: Double?; var id: String { date } }
private struct WidgetRecord: Encodable {
    let generatedAt: String; let measuredAt: String?; let date: String; let mode: String
    let recovery: Double?; let recoveryStatus: String; let strain: Double?; let strainStatus: String
    let sleep: Double?; let sleepStatus: String; let age: Double?; let ageStatus: String; let ageCollectedDays: Int
    let activityMinutes: Double?; let activityBaselineMinutes: Double?; let activityCoverage: Double?
}

func numberText(_ value: Double?, digits: Int = 0) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(digits)))
}
func durationText(_ minutes: Double?) -> String {
    guard let minutes else { return "—" }
    return "\(Int(minutes)/60)h \(Int(minutes)%60)m"
}
