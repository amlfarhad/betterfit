import Foundation
import Testing
@testable import AirSync

@Test(.enabled(if: ProcessInfo.processInfo.environment["FORM_SYNC_BENCHMARK"] == "1"))
func syntheticLargeHistoryBenchmark() throws {
    let zone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_790_683_200)
    let count = 90_000
    let start = now.addingTimeInterval(Double(-count * 4))
    let formatter = ISO8601DateFormatter()
    var points: [JSONValue] = []
    points.reserveCapacity(count)
    for index in 0..<count {
        points.append(.object([
            "dataPointName": .string("users/synthetic/dataTypes/heart-rate/dataPoints/sample-\(index)"),
            "heartRate": .object([
                "sampleTime": .object(["physicalTime": .string(formatter.string(from: start.addingTimeInterval(Double(index * 4)))), "utcOffset": .string("0s")]),
                "beatsPerMinute": .number(Double(60 + index % 40))
            ])
        ]))
    }
    var cache = SyncCache()
    cache.ageYears = 40
    func measure<T>(_ name: String, operation: () throws -> T) rethrows -> T {
        let began = Date()
        let result = try operation()
        print("FORM_BENCH \(name): \(String(format: "%.3f", Date().timeIntervalSince(began)))s")
        return result
    }
    let input = try measure("normalize-90000") {
        try HealthNormalizer.normalize(records: [.heartRate: points], ageYears: 40, now: now, timeZone: zone)
    }
    #expect(abs(input.days.flatMap(\.heartRateBins).reduce(0) { $0 + $1.seconds } - Double((count - 1) * 4)) < 0.001)
    try measure("initial-replacement-90000") {
        try cache.replace(.heartRate, window: QueryWindow(start: start, end: now), points: points, at: now, timeZone: zone)
    }
    let recent = Array(points.suffix(1_800))
    try measure("warm-replacement-1800-of-90000") {
        try cache.replace(.heartRate, window: QueryWindow(start: now.addingTimeInterval(-7_200), end: now), points: recent, at: now, timeZone: zone)
    }
    #expect(cache.records[.heartRate]?.count == count)
    _ = measure("freshness-90000") { cache.freshness(now: now, timeZone: zone) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try measure("encode-save-90000") { try cache.write(to: directory.appendingPathComponent("synthetic-cache.json")) }
}
