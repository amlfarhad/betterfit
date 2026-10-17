import Foundation
import Testing
import FitbitMetrics
@testable import AirSync

private struct ParityFixture: Decodable {
    let records: [String: [JSONValue]]
    let ageYears: Double
    let capturedAt: String
    let timeZone: String
    let completedWindows: [String: [[String]]]
    let expected: InputBundle
}

private enum ParityFailure: Error { case unknownMetric, invalidWindow, mismatch }

/// Optional local-only check. No fixture or account measurements are shipped in the package.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AIRSYNC_PARITY_FIXTURE"] != nil))
func privatePythonNormalizationParity() throws {
    guard let path = ProcessInfo.processInfo.environment["AIRSYNC_PARITY_FIXTURE"] else { return }
    let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard let zone = TimeZone(identifier: fixture.timeZone) else { throw ParityFailure.invalidWindow }
    var records: [HealthMetric: [JSONValue]] = [:]
    for (key, value) in fixture.records {
        guard let metric = HealthMetric(rawValue: key) else { throw ParityFailure.unknownMetric }
        records[metric] = value
    }
    var windows: [HealthMetric: [QueryWindow]] = [:]
    for (key, values) in fixture.completedWindows {
        guard let metric = HealthMetric(rawValue: key) else { throw ParityFailure.unknownMetric }
        windows[metric] = try values.map { pair in
            guard pair.count == 2 else { throw ParityFailure.invalidWindow }
            return QueryWindow(start: try SyncDates.instant(.string(pair[0])), end: try SyncDates.instant(.string(pair[1])))
        }
    }
    let actual = try HealthNormalizer.normalize(records: records, ageYears: fixture.ageYears,
        now: SyncDates.instant(.string(fixture.capturedAt)), timeZone: zone, completedWindows: windows)
    // The Python exporter predates optional BetterFit details. Compare its
    // original projection while still checking the unchanged score output.
    var originalProjection = actual
    for index in originalProjection.days.indices {
        originalProjection.days[index].oxygenSaturationPercent = nil
        originalProjection.days[index].respiratoryRateBrpm = nil
        originalProjection.days[index].skinTemperatureCelsius = nil
        originalProjection.days[index].sleep?.lightMinutes = nil
        originalProjection.days[index].sleep?.deepMinutes = nil
        originalProjection.days[index].sleep?.remMinutes = nil
        originalProjection.days[index].sleep?.startTime = nil
        originalProjection.days[index].sleep?.endTime = nil
    }
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let a = try decoder.decode(JSONValue.self, from: encoder.encode(originalProjection))
    let b = try decoder.decode(JSONValue.self, from: encoder.encode(fixture.expected))
    // Throw an opaque error instead of assertion-macro values that could reveal private data.
    guard equivalent(a, b) else { throw ParityFailure.mismatch }
    let actualScores = try MetricsEngine.evaluate(actual), expectedScores = try MetricsEngine.evaluate(fixture.expected)
    let c = try decoder.decode(JSONValue.self, from: encoder.encode(actualScores))
    let d = try decoder.decode(JSONValue.self, from: encoder.encode(expectedScores))
    guard equivalent(c, d) else { throw ParityFailure.mismatch }
}

private func equivalent(_ left: JSONValue, _ right: JSONValue, key: String = "") -> Bool {
    switch (left, right) {
    case (.number(let a), .number(let b)): return abs(a - b) <= 0.000001
    case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { equivalent($0, $1) }
    case (.object(let a), .object(let b)):
        return a.keys.sorted() == b.keys.sorted() && a.allSatisfy { field, value in equivalent(value, b[field]!, key: field) }
    case (.string(let a), .string(let b)) where key == "generatedAt":
        guard let first = try? SyncDates.instant(.string(a)), let second = try? SyncDates.instant(.string(b)) else { return false }
        return abs(first.timeIntervalSince(second)) < 0.001
    default: return left == right
    }
}
