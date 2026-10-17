import Foundation
import Testing
@testable import AirUI

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["FORM_SYNC_BENCHMARK"] == "1"))
func repeatedTrendDatePresentationBenchmark() throws {
    let start = Date()
    for _ in 0..<20 {
        for day in 1...28 {
            let key = String(format: "2026-09-%02d", day)
            _ = FormModel.dateLabel(key, format: "EEEE")
            _ = FormModel.dateLabel(key, format: "MMM d")
            _ = FormModel.dateKey(try #require(FormModel.calendarDate(key)))
        }
    }
    print("FORM_BENCH trend-date-presentation-20-updates: \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    #expect(FormModel.dateKey(try #require(FormModel.calendarDate("2026-09-29"))) == "2026-09-29")
}
