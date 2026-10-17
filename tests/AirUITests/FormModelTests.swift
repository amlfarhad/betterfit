import Foundation
import Testing
import FitbitMetrics
import AirSync
import AirAuth
@testable import AirUI

@MainActor
struct FormModelTests {
    private func sample() -> InputBundle {
        FormDemo.input(now: Date(timeIntervalSince1970: 1_790_704_800))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    @Test func widgetLinkOpensLatestSnapshotInsteadOfPreviouslySelectedHistory() throws {
        let input = sample()
        let model = FormModel(input: input, mode: .imported, preview: true)
        model.selectedDate = try #require(input.days.dropLast().last?.date)
        model.open(URL(string: "form://metric/recovery")!)
        #expect(model.selectedMetric == .recovery)
        #expect(model.selectedDate == input.asOfDate)
    }

    @Test func rejectedImportPreservesLastValidDataAndSelection() throws {
        let model = FormModel(input: sample(), mode: .imported, preview: true)
        model.selectedDate = try #require(model.input?.days.dropLast().last?.date)
        let previousInput = try encoded(model.input), previousScores = try encoded(model.scores)
        let previousDate = model.selectedDate, previousTarget = model.sleepTarget
        model.importCanonical(Data("not a snapshot".utf8))
        #expect(try encoded(model.input) == previousInput)
        #expect(try encoded(model.scores) == previousScores)
        #expect(model.selectedDate == previousDate)
        #expect(model.sleepTarget == previousTarget)
        #expect(model.mode == .imported)
        #expect(model.syncError != nil)
        var invalid = sample(); invalid.schemaVersion = 999
        model.importCanonical(try encoded(invalid))
        #expect(try encoded(model.input) == previousInput)
        #expect(try encoded(model.scores) == previousScores)
        #expect(model.selectedDate == previousDate)
    }

    @Test func explicitImportAndSampleKeepDistinctModes() throws {
        let model = FormModel(preview: true)
        model.exploreDemo()
        #expect(model.mode == .demo)
        #expect(model.modeLabel == "Sample data")
        #expect(model.lastMeasured == nil)
        model.importCanonical(try encoded(sample()))
        #expect(model.mode == .imported)
        #expect(model.modeLabel == "Saved snapshot")
        #expect(model.syncError == nil)
        model.exploreDemo()
        #expect(model.mode == .demo)
        #expect(model.lastChecked == nil)
        #expect(model.lastMeasured == nil)
        #expect(model.lastSuccessfulSync == nil)
    }

    @Test func historyRetainsMissingDaysAndNeverFallsBackToAnotherSelection() throws {
        var input = sample()
        let missing = input.days.remove(at: input.days.count - 3).date
        let model = FormModel(input: input, mode: .imported, preview: true)
        let history = model.history(.steps, count: 7)
        #expect(history.count == 7)
        #expect(history.first(where: { $0.date == missing })?.value == nil)
        model.selectedDate = missing
        #expect(model.currentDay == nil)
        #expect(model.currentInput == nil)
        #expect(model.score(.sleep) == nil)
        #expect(model.value(.steps, date: missing) == nil)
        model.selectedDate = input.asOfDate
        #expect(model.currentInput?.date == input.asOfDate)
        #expect(model.value(.steps, date: input.asOfDate) == input.days.last?.steps)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 359.0, 721.0])
    func invalidSleepTargetDoesNotChangeScores(value: Double) throws {
        let model = FormModel(input: sample(), mode: .imported, preview: true)
        let previousInput = try encoded(model.input), previousScores = try encoded(model.scores)
        let previousTarget = model.sleepTarget
        model.updateSleepTarget(value)
        #expect(model.sleepTarget == previousTarget)
        #expect(try encoded(model.input) == previousInput)
        #expect(try encoded(model.scores) == previousScores)
    }

    @Test func validSleepTargetRecomputesLocallyAndPreservesSelectedDay() throws {
        let model = FormModel(input: sample(), mode: .imported, preview: true)
        model.selectedDate = try #require(model.input?.days.dropLast().last?.date)
        let selected = model.selectedDate
        model.updateSleepTarget(600)
        #expect(model.input?.sleepTargetMinutes == 600)
        #expect(model.sleepTarget == 600)
        #expect(model.selectedDate == selected)
        let input = try #require(model.input)
        #expect(try encoded(model.scores) == encoded(MetricsEngine.evaluate(input)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("form-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isolatedModel(at directory: URL) throws -> FormModel {
        let model = FormModel(storageDirectory: directory)
        // These tests must never open a configured host's account or widget store.
        try #require(!model.configurationAvailable)
        try #require(Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") == nil)
        return model
    }

    @Test func previewNeverReadsOrChangesPersistedData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["imported-snapshot.json", "health-cache.json", "preferences.json"]
        for file in files { try Data("untouched".utf8).write(to: directory.appendingPathComponent(file)) }
        let model = FormModel(input: sample(), mode: .imported, preview: true, storageDirectory: directory)
        #expect(!model.configurationAvailable)
        await model.startup()
        model.importCanonical(try encoded(sample()))
        model.updateSleepTarget(600)
        model.exploreDemo()
        await model.connect()
        await model.refresh()
        await model.disconnect()
        #expect(model.input == nil)
        #expect(model.scores == nil)
        #expect(model.mode == .disconnected)
        #expect(model.lastChecked == nil)
        for file in files {
            #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == Data("untouched".utf8))
        }
    }

    @Test func importedModeAndChangedSleepTargetSurviveRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try isolatedModel(at: directory)
        first.importCanonical(try encoded(sample()))
        first.updateSleepTarget(600)
        #expect(first.syncError == nil)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.mode == .imported)
        #expect(reopened.sleepTarget == 600)
        #expect(reopened.input?.sleepTargetMinutes == 600)
        #expect(try encoded(reopened.scores) == encoded(first.scores))
        #expect(reopened.lastChecked == nil)
        await reopened.refresh(force: true)
        #expect(reopened.mode == .imported)
        #expect(reopened.notice != nil)
    }

    @Test func explicitDemoSelectionSurvivesExistingImportedSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try isolatedModel(at: directory)
        first.importCanonical(try encoded(sample()))
        let originalFile = try Data(contentsOf: directory.appendingPathComponent("imported-snapshot.json"))
        first.exploreDemo()
        first.updateSleepTarget(570)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.mode == .demo)
        #expect(reopened.sleepTarget == 570)
        #expect(reopened.lastChecked == nil)
        #expect(reopened.lastMeasured == nil)
        #expect(reopened.lastSuccessfulSync == nil)
        #expect(reopened.input?.days.allSatisfy { $0.sourceKey == "synthetic-demo:v1" } == true)
        #expect(try Data(contentsOf: directory.appendingPathComponent("imported-snapshot.json")) == originalFile)
        let preferences = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("preferences.json"))) as? [String: Any]
        #expect(preferences?.count == 2)
        #expect(preferences?["mode"] as? String == "demo")
        await reopened.refresh(force: true)
        #expect(reopened.mode == .demo)
    }

    @Test func corruptPreferencesDoNotSilentlyRestoreAnotherSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try encoded(sample()).write(to: directory.appendingPathComponent("imported-snapshot.json"))
        try Data(#"{"mode":"connected","sleepTarget":-1}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        await model.startup()
        #expect(model.mode == .disconnected)
        #expect(model.input == nil)
        #expect(model.syncError != nil)
    }

    @Test func disconnectClearsPrivateFilesAndDoesNotRestoreOnRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        model.importCanonical(try encoded(sample()))
        model.updateSleepTarget(600)
        try Data("synthetic cache".utf8).write(to: directory.appendingPathComponent("health-cache.json"))
        await model.disconnect()
        #expect(model.mode == .disconnected)
        #expect(model.sleepTarget == 480)
        #expect(model.input == nil)
        #expect(model.scores == nil)
        #expect(model.syncError == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.mode == .disconnected)
        #expect(reopened.input == nil)
    }

    @Test func failedPreferenceWritePreservesImportedFileAndAppliedTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        model.importCanonical(try encoded(sample()))
        let previous = try Data(contentsOf: directory.appendingPathComponent("imported-snapshot.json"))
        let previousInput = try encoded(model.input)
        let target = model.sleepTarget
        let preferences = directory.appendingPathComponent("preferences.json")
        try FileManager.default.removeItem(at: preferences)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
        var different = sample(); different.ageYears = 45
        model.importCanonical(try encoded(different))
        #expect(model.syncError != nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("imported-snapshot.json")) == previous)
        #expect(try encoded(model.input) == previousInput)
        model.updateSleepTarget(600)
        #expect(model.sleepTarget == target)
        #expect(try encoded(model.input) == previousInput)
        model.exploreDemo()
        #expect(model.mode == .imported)
    }

    @Test(arguments: [true, false])
    func cancelledOrFailedConsentPreservesOfflineCache(cancelled: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        model.importCanonical(try encoded(sample()))
        let cache = directory.appendingPathComponent("health-cache.json")
        try Data("previous account cache".utf8).write(to: cache)
        let originalPreferences = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
        var events: [String] = []
        model.accountOperations = FormAccountOperations(
            signIn: { events.append("signIn"); if cancelled { throw CancellationError() }; throw SyncError.network },
            hasCredentials: { true }, load: { _ in nil },
            refresh: { _, _ in events.append("refresh"); throw SyncError.network },
            clear: { events.append("clear"); try FileManager.default.removeItem(at: cache) },
            disconnect: { events.append("disconnect") })
        await model.connect()
        #expect(events == ["signIn"])
        #expect(try Data(contentsOf: cache) == Data("previous account cache".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("preferences.json")) == originalPreferences)
        #expect(model.mode == .imported)
        #expect(model.input != nil)
        #expect(!model.isRefreshing)
    }

    @Test func cacheClearFailureAfterConsentDiscardsNewCredentialsBeforeAnyRefresh() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        model.importCanonical(try encoded(sample()))
        var events: [String] = []
        model.accountOperations = FormAccountOperations(
            signIn: { events.append("signIn") }, hasCredentials: { true }, load: { _ in nil },
            refresh: { _, _ in events.append("refresh"); throw SyncError.network },
            clear: { events.append("clear"); throw SyncError.unsafeCache },
            disconnect: { events.append("disconnect") })
        await model.connect()
        #expect(events == ["signIn", "clear", "disconnect"])
        #expect(model.mode == .disconnected)
        #expect(model.input == nil)
        #expect(model.scores == nil)
        #expect(model.syncError != nil)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.mode == .disconnected)
        #expect(reopened.input == nil)
    }

    @Test func successfulConsentClearsCacheBeforeFirstNewAccountRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        model.importCanonical(try encoded(sample()))
        var events: [String] = []
        model.accountOperations = FormAccountOperations(
            signIn: { events.append("signIn") },
            hasCredentials: { events.append("credentials"); return true }, load: { _ in nil },
            refresh: { _, _ in events.append("refresh"); throw SyncError.network },
            clear: { events.append("clear") }, disconnect: { events.append("disconnect") })
        await model.connect()
        #expect(events == ["signIn", "clear", "credentials", "refresh"])
        #expect(model.mode == .connected)
        #expect(model.input == nil)
    }

    @Test func concurrentStartupCallersBothWaitForRestoration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"mode":"connected","sleepTarget":480}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        var continuation: CheckedContinuation<Void, Never>?
        var loadCount = 0
        var credentialChecks = 0
        var secondStarted = false
        var secondCompleted = false
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { credentialChecks += 1; return false },
            load: { _ in loadCount += 1; await withCheckedContinuation { continuation = $0 }; return nil },
            refresh: { _, _ in throw SyncError.network }, clear: {}, disconnect: {})
        let first = Task { await model.startup() }
        while continuation == nil { await Task.yield() }
        let second = Task { secondStarted = true; await model.startup(); secondCompleted = true }
        let concurrentRefresh = Task { await model.refresh(force: false) }
        while !secondStarted { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }
        #expect(!secondCompleted)
        #expect(credentialChecks == 0)
        continuation?.resume()
        await first.value
        await second.value
        await concurrentRefresh.value
        await model.startup()
        #expect(loadCount == 1)
        #expect(secondCompleted)
    }

    @Test func reopeningCannotStartConsentWhileSavedSourceIsRestoring() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = Data(#"{"mode":"connected","sleepTarget":480}"#.utf8)
        try preferences.write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        var continuation: CheckedContinuation<Void, Never>?
        var events: [String] = []
        #expect(!model.showsWelcome)
        #expect(model.isLoadingSavedSource)
        model.accountOperations = FormAccountOperations(
            signIn: { events.append("signIn") }, hasCredentials: { true },
            load: { _ in await withCheckedContinuation { continuation = $0 }; return nil },
            refresh: { _, _ in events.append("refresh"); throw SyncError.network },
            clear: { events.append("clear") }, disconnect: { events.append("disconnect") })
        let restoration = Task { await model.startup() }
        while continuation == nil { await Task.yield() }
        #expect(!model.showsWelcome)
        #expect(model.isLoadingSavedSource)
        let connection = Task { await model.connect() }
        for _ in 0..<10 { await Task.yield() }
        continuation?.resume()
        await restoration.value
        await connection.value
        #expect(!events.contains("signIn"))
        #expect(!events.contains("clear"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("preferences.json")) == preferences)
        #expect(model.mode == .connected)
        #expect(!model.showsWelcome)
        #expect(!model.isLoadingSavedSource)
        #expect(!model.needsReauthorization)
    }

    @Test func firstLaunchShowsWelcomeOnlyAfterCheckingSavedSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try isolatedModel(at: directory)
        #expect(!model.showsWelcome)
        await model.startup()
        #expect(model.showsWelcome)
        #expect(!model.isLoadingSavedSource)
    }

    @Test(arguments: [true, false])
    func unavailableCredentialsDoNotSilentlyStartConsent(hasCredentials: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"mode":"connected","sleepTarget":480}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        var consentCount = 0
        model.accountOperations = FormAccountOperations(
            signIn: { consentCount += 1 }, hasCredentials: { hasCredentials }, load: { _ in nil },
            refresh: { _, _ in throw OAuthError.networkUnavailable }, clear: {}, disconnect: {})
        await model.startup()
        #expect(consentCount == 0)
        #expect(model.mode == .connected)
        #expect(!model.showsWelcome)
        #expect(model.needsReauthorization == !hasCredentials)
    }

    @Test(arguments: [401, 403, 500])
    func savedSessionDistinguishesAccessFailureFromTransientFailure(status: Int) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"mode":"connected","sleepTarget":480}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        var consentCount = 0
        model.accountOperations = FormAccountOperations(
            signIn: { consentCount += 1 }, hasCredentials: { true }, load: { _ in nil },
            refresh: { _, _ in throw SyncError.http(status) }, clear: {}, disconnect: {})
        await model.startup()
        #expect(consentCount == 0)
        #expect(!model.showsWelcome)
        #expect(model.needsReauthorization == (status == 401 || status == 403))
        #expect(!model.isRefreshing)
        #expect(model.syncError != nil)
    }

    @Test func unreadableSavedCacheKeepsSessionAndAllowsExplicitDisconnectRecovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"mode":"connected","sleepTarget":480}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let model = try isolatedModel(at: directory)
        var clearCount = 0
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { true }, load: { _ in throw SyncError.incompatibleCache },
            refresh: { _, _ in throw SyncError.incompatibleCache }, clear: { clearCount += 1 }, disconnect: {})
        await model.startup()
        #expect(model.mode == .connected)
        #expect(model.syncError != nil)
        #expect(!model.needsReauthorization)
        #expect(!model.isLoadingSavedSource && !model.isRefreshing)
        #expect(clearCount == 0)
        await model.disconnect()
        #expect(clearCount == 1)
        #expect(model.showsWelcome)
    }
}
