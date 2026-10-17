import Foundation
import Testing
import FitbitMetrics
@testable import AirSync
@testable import AirUI

@MainActor
struct SavedDashboardTests {
    private let instant = Date(timeIntervalSince1970: 1_790_704_800)

    private func sample(age: Double = 36) -> InputBundle {
        var input = FormDemo.input(now: instant)
        input.ageYears = age
        for index in input.days.indices { input.days[index].sourceKey = "synthetic-test-connected" }
        return input
    }

    private func record(input: InputBundle? = nil, timeZone: String = TimeZone.current.identifier) -> SavedDashboard {
        SavedDashboard(input: input ?? sample(), timeZone: timeZone,
                       checkedAt: instant, measuredAt: instant.addingTimeInterval(-120),
                       successfulAt: instant.addingTimeInterval(-60))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("betterfit-dashboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isolatedModel(at directory: URL) throws -> FormModel {
        let model = FormModel(storageDirectory: directory)
        // Never read this host's credentials, widgets, or persisted health data.
        try #require(!model.configurationAvailable)
        try #require(Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") == nil)
        return model
    }

    private func seed(_ directory: URL, dashboard: SavedDashboard? = nil, mode: FormDataMode? = .connected, target: Double = 480) throws {
        try encoded(dashboard ?? record()).write(to: directory.appendingPathComponent("saved-dashboard.json"))
        if let mode {
            let preferences: [String: Any] = ["mode": mode.rawValue, "sleepTarget": target]
            try JSONSerialization.data(withJSONObject: preferences).write(to: directory.appendingPathComponent("preferences.json"))
        }
    }

    private func snapshot(_ input: InputBundle) throws -> SyncSnapshot {
        SyncSnapshot(input: input, scores: try MetricsEngine.evaluate(input),
                     freshness: SyncFreshness(checkedAt: instant.addingTimeInterval(60),
                         lastSuccessfulSync: instant.addingTimeInterval(60), lastMeasurementAt: instant,
                         failures: [], revision: 2, sourcePolicy: "synthetic-test-reconciled", ageProvenance: "synthetic-test"))
    }

    private func longHistory(daySpacing: Int = 1) throws -> InputBundle {
        var input = sample()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let end = try #require(formatter.date(from: input.asOfDate))
        input.days = stride(from: 159, through: 0, by: -daySpacing).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: end)!
            return DailyInput(date: formatter.string(from: date), sourceKey: "synthetic-test-connected",
                dayDurationSeconds: 86_400, elapsedSeconds: 86_400, isClosed: offset > 0,
                steps: Double(8_000 + offset), stepsComplete: true,
                heartRateBins: [HeartRateBin(bpm: 75, seconds: 86_400)], rmssdMs: 40, restingHeartRate: 60,
                sleep: SleepInput(asleepMinutes: 480, periodMinutes: 500, midpointMinute: 180))
        }
        return input
    }

    @Test func validCompactCacheRecalculatesIdenticalScoresAndRetainsFreshness() throws {
        let expected = record()
        let data = try encoded(expected)
        #expect(data.count < SavedDashboard.maximumBytes)
        let restored = try SavedDashboard.restore(data, timeZone: .current, target: 480)
        #expect(try encoded(restored.record.input) == encoded(expected.input))
        #expect(try encoded(restored.scores) == encoded(MetricsEngine.evaluate(expected.input)))
        #expect(restored.record.checkedAt == expected.checkedAt)
        #expect(restored.record.measuredAt == expected.measuredAt)
        #expect(restored.record.successfulAt == expected.successfulAt)
    }

    @Test(arguments: [1, 3])
    func compactCacheKeepsOnlyLast56CalendarDatesAndPreservesVisibleScores(daySpacing: Int) throws {
        let input = try longHistory(daySpacing: daySpacing)
        let compact = record(input: input)
        let expected = input.days.filter { day in
            // The fixture spans 160 dates. The final 56 dates begin 104 days into it.
            day.date >= input.days[104 / daySpacing + (104 % daySpacing == 0 ? 0 : 1)].date
        }
        #expect(compact.input.days.count == (daySpacing == 1 ? 56 : 19))
        #expect(try encoded(compact.input.days) == encoded(expected), "Sparse history must be trimmed by calendar date, not merely record count")
        #expect(compact.input.asOfDate == input.asOfDate)
        #expect(compact.input.generatedAt == input.generatedAt)
        #expect(compact.checkedAt == instant)
        let restored = try SavedDashboard.restore(encoded(compact), timeZone: .current, target: 480)
        let fullScores = try MetricsEngine.evaluate(input)
        let visibleCount = daySpacing == 1 ? 28 : 10
        #expect(try encoded(Array(restored.scores.days.suffix(visibleCount))) == encoded(Array(fullScores.days.suffix(visibleCount))),
                "The compact window retains enough prior days for the visible scores")
    }

    @Test func underByteLimitCacheWithTooManyDaysIsRejectedBeforeScoreCalculation() throws {
        let input = try longHistory()
        var tampered = try JSONSerialization.jsonObject(with: encoded(record(input: input))) as! [String: Any]
        tampered["input"] = try JSONSerialization.jsonObject(with: encoded(input))
        let data = try JSONSerialization.data(withJSONObject: tampered)
        #expect(data.count < SavedDashboard.maximumBytes, "Byte limits alone do not bound score computation")
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: .current, target: 480) }
    }

    @Test(arguments: [0, 2, 999])
    func unknownCacheVersionCannotRestore(version: Int) throws {
        var unsupported = record()
        unsupported.version = version
        let data = try encoded(unsupported)
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: .current, target: 480) }
    }

    @Test(arguments: ["Not/A_TimeZone", "Pacific/Kiritimati"])
    func mismatchedOrInvalidTimeZoneCannotReuseDailyBoundaries(timeZone: String) throws {
        let data = try encoded(record(timeZone: timeZone))
        let expectedZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: expectedZone, target: 480) }
    }

    @Test func changedSleepTargetCannotRestoreScoresForOldTarget() throws {
        let data = try encoded(record())
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: .current, target: 600) }
    }

    @Test(arguments: [1.0, 359.0, 721.0, 1440.0])
    func matchingCacheAndPreferencesCannotBypassConnectedSleepTargetLimits(target: Double) throws {
        var input = sample()
        input.sleepTargetMinutes = target
        let data = try encoded(record(input: input))
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: .current, target: target) }
    }

    @Test(arguments: ["schema", "date", "negativeSteps", "duplicateDay", "missingSource"])
    func invalidCanonicalInputIsRejectedBeforePresentation(problem: String) throws {
        var input = sample()
        switch problem {
        case "schema": input.schemaVersion = 999
        case "date": input.asOfDate = "2026-02-31"
        case "negativeSteps": input.days[0].steps = -1
        case "duplicateDay": input.days.append(input.days[0])
        default: input.days[0].sourceKey = ""
        }
        let data = try encoded(record(input: input))
        #expect(throws: (any Error).self) { try SavedDashboard.restore(data, timeZone: .current, target: 480) }
    }

    @Test func oversizedCacheIsRejectedBeforeDecoding() throws {
        let oversized = Data(repeating: 32, count: SavedDashboard.maximumBytes + 1)
        do {
            _ = try SavedDashboard.restore(oversized, timeZone: .current, target: 480)
            Issue.record("An oversized compact cache was accepted")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadTooLarge)
        }
    }

    @Test func compactDashboardAppearsBeforeGatedRawRestoreAndRawDataWinsAfterward() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = record()
        try seed(directory, dashboard: saved)
        let model = try isolatedModel(at: directory)
        var continuation: CheckedContinuation<Void, Never>?
        var raw = sample(age: 42)
        raw.days[raw.days.count - 1].steps = 1234
        let authoritative = try snapshot(raw)
        var credentialChecks = 0
        model.accountOperations = FormAccountOperations(
            signIn: { Issue.record("Startup must not start consent") },
            hasCredentials: { credentialChecks += 1; return false },
            load: { _ in await withCheckedContinuation { continuation = $0 }; return authoritative },
            refresh: { _, _ in throw SyncError.network }, clear: {}, disconnect: {})
        #expect(model.isLoadingSavedSource && !model.showsWelcome)
        let startup = Task { await model.startup() }
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        guard let release = continuation else {
            startup.cancel()
            Issue.record("Raw restoration did not reach its test gate")
            return
        }
        #expect(model.mode == .connected)
        #expect(model.input?.ageYears == saved.input.ageYears)
        #expect(model.selectedDate == saved.input.asOfDate)
        #expect(model.lastChecked == saved.checkedAt && model.lastMeasured == saved.measuredAt)
        #expect(model.lastSuccessfulSync == saved.successfulAt)
        #expect(!model.isLoadingSavedSource && !model.showsWelcome)
        #expect(credentialChecks == 0, "Raw restoration remains in progress while compact data is already visible")
        release.resume()
        await startup.value
        #expect(try encoded(model.input) == encoded(Optional(raw)))
        #expect(try encoded(model.scores) == encoded(Optional(authoritative.scores)))
        #expect(model.lastMeasured == authoritative.freshness.lastMeasurementAt)
        #expect(credentialChecks == 1)
        let rewritten = try SavedDashboard.restore(Data(contentsOf: directory.appendingPathComponent("saved-dashboard.json")), timeZone: .current, target: 480)
        #expect(rewritten.record.input.ageYears == 42, "The reconciled raw snapshot replaces the provisional display cache")
    }

    @Test(arguments: [FormDataMode.disconnected, .imported, .demo])
    func explicitNonconnectedSourcesNeverHydrateConnectedDashboard(mode: FormDataMode) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory, dashboard: record(input: sample(age: 91)), mode: mode)
        let imported = sample(age: 25)
        try encoded(imported).write(to: directory.appendingPathComponent("imported-snapshot.json"))
        let model = try isolatedModel(at: directory)
        var accountCalls = 0
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { accountCalls += 1; return true },
            load: { _ in accountCalls += 1; return nil },
            refresh: { _, _ in accountCalls += 1; throw SyncError.network }, clear: {}, disconnect: {})
        await model.startup()
        #expect(model.mode == mode)
        #expect(accountCalls == 0)
        #expect(model.input?.ageYears != 91)
        #expect(model.lastChecked == nil && model.lastMeasured == nil && model.lastSuccessfulSync == nil)
        switch mode {
        case .imported: #expect(try encoded(model.input) == encoded(Optional(imported)))
        case .demo: #expect(model.input?.days.allSatisfy { $0.sourceKey == "synthetic-demo:v1" } == true)
        default: #expect(model.input == nil && model.scores == nil && model.showsWelcome)
        }
    }

    @Test func orphanedCacheWithoutSavedConnectedPreferenceCannotCreateSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory, mode: nil)
        let model = try isolatedModel(at: directory)
        var accountCalls = 0
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { accountCalls += 1; return true },
            load: { _ in accountCalls += 1; return nil }, refresh: { _, _ in throw SyncError.network }, clear: {}, disconnect: {})
        await model.startup()
        #expect(model.mode == .disconnected && model.input == nil && model.scores == nil)
        #expect(model.showsWelcome && accountCalls == 0)
    }

    @Test func invalidCompactCacheFallsThroughToRawRestoration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var invalid = record(); invalid.version = 500
        try seed(directory, dashboard: invalid)
        let model = try isolatedModel(at: directory)
        let raw = try snapshot(sample(age: 44))
        var loadCount = 0
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { false },
            load: { _ in
                loadCount += 1
                #expect(model.input == nil && model.scores == nil)
                #expect(model.isLoadingSavedSource && !model.showsWelcome)
                return raw
            }, refresh: { _, _ in throw SyncError.network }, clear: {}, disconnect: {})
        await model.startup()
        #expect(loadCount == 1 && model.input?.ageYears == 44)
        #expect(model.mode == .connected && !model.showsWelcome)
    }

    @Test func disconnectRemovesCompactCacheAndDelayedRawRestoreCannotResurrectIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory)
        let model = try isolatedModel(at: directory)
        let raw = try snapshot(sample())
        var continuation: CheckedContinuation<Void, Never>?
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { true },
            load: { _ in await withCheckedContinuation { continuation = $0 }; return raw },
            refresh: { _, _ in throw SyncError.network }, clear: {}, disconnect: {})
        let startup = Task { await model.startup() }
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        guard let release = continuation else {
            startup.cancel(); Issue.record("Raw restoration did not reach its test gate"); return
        }
        #expect(model.input != nil)
        await model.disconnect()
        #expect(model.mode == .disconnected && model.input == nil && model.scores == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("saved-dashboard.json").path))
        release.resume()
        await startup.value
        #expect(model.mode == .disconnected && model.input == nil && model.scores == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.showsWelcome && reopened.input == nil)
    }

    @Test(arguments: [true, false])
    func interruptedDisconnectCannotRestoreConnectedDataBeforeAsyncCleanupCompletes(pauseCredentialRemoval: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory)
        let compactURL = directory.appendingPathComponent("saved-dashboard.json")
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        let rawURL = directory.appendingPathComponent("health-cache-v2.json")
        try Data("synthetic pending raw cleanup".utf8).write(to: rawURL)
        let model = try isolatedModel(at: directory)
        await model.startup()
        #expect(model.mode == .connected && model.input != nil)
        var continuation: CheckedContinuation<Void, Never>?
        model.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { true }, load: { _ in nil },
            refresh: { _, _ in throw SyncError.network },
            clear: { if !pauseCredentialRemoval { await withCheckedContinuation { continuation = $0 } } },
            disconnect: { if pauseCredentialRemoval { await withCheckedContinuation { continuation = $0 } } })
        let removal = Task { await model.disconnect() }
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        guard let release = continuation else {
            removal.cancel(); Issue.record("Disconnect did not reach its asynchronous cleanup gate"); return
        }
        var released = false
        defer { if !released { release.resume() } }
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: preferencesURL)) as! [String: Any]
        #expect(persisted["mode"] as? String == "disconnected", "The source fence must be durable before either cleanup suspension")
        #expect(!FileManager.default.fileExists(atPath: compactURL.path))
        #expect(FileManager.default.fileExists(atPath: rawURL.path), "Raw cleanup is intentionally still pending")
        let restarted = try isolatedModel(at: directory)
        var accountCalls = 0
        restarted.accountOperations = FormAccountOperations(
            signIn: {}, hasCredentials: { accountCalls += 1; return true },
            load: { _ in accountCalls += 1; return nil },
            refresh: { _, _ in accountCalls += 1; throw SyncError.network }, clear: {}, disconnect: {})
        await restarted.startup()
        #expect(restarted.mode == .disconnected && restarted.input == nil && restarted.scores == nil)
        #expect(restarted.showsWelcome && accountCalls == 0, "A replacement process cannot rehydrate the retiring account")
        release.resume(); released = true
        await removal.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func newAccountRetiresCompactCacheBeforeClearingOrRequestingRawData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory)
        let cacheURL = directory.appendingPathComponent("saved-dashboard.json")
        let model = try isolatedModel(at: directory)
        await model.startup()
        #expect(model.mode == .connected && model.input != nil, "Begin from the displayed previous account")
        var events: [String] = []
        model.accountOperations = FormAccountOperations(
            signIn: {
                events.append("consent")
                let preferences = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("preferences.json"))) as! [String: Any]
                #expect(preferences["mode"] as? String == "disconnected", "A process interruption during consent cannot restore the old account")
            }, hasCredentials: { events.append("credentials"); return true }, load: { _ in nil },
            refresh: { _, _ in
                events.append("refresh")
                #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
                #expect(model.input == nil && model.scores == nil)
                throw SyncError.network
            }, clear: {
                events.append("clear")
                #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
                #expect(model.input == nil && model.scores == nil)
            }, disconnect: {})
        await model.connect()
        #expect(events == ["consent", "clear", "credentials", "refresh"])
        #expect(model.mode == .connected && model.input == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func cancelledConsentPreservesCompactCacheAndConnectedPreference() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(directory)
        let cacheURL = directory.appendingPathComponent("saved-dashboard.json")
        let before = try Data(contentsOf: cacheURL)
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        let previousPreferences = try Data(contentsOf: preferencesURL)
        let model = try isolatedModel(at: directory)
        await model.startup()
        let previousInput = try encoded(model.input)
        model.accountOperations = FormAccountOperations(
            signIn: { throw CancellationError() }, hasCredentials: { false }, load: { _ in nil },
            refresh: { _, _ in throw SyncError.network },
            clear: { Issue.record("Cancelled consent cannot remove the current account's cache") }, disconnect: {})
        await model.connect()
        #expect(model.mode == .connected && model.input != nil)
        #expect(try encoded(model.input) == previousInput)
        #expect(try Data(contentsOf: cacheURL) == before)
        #expect(try Data(contentsOf: preferencesURL) == previousPreferences)
        let reopened = try isolatedModel(at: directory)
        await reopened.startup()
        #expect(reopened.mode == .connected && reopened.input != nil && !reopened.showsWelcome)
    }
}
