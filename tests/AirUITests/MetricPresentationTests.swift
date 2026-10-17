import Foundation
import Testing
import AirSync
import FitbitMetrics
@testable import AirUI

@MainActor
struct MetricPresentationTests {
    private func input(issue: String? = nil) -> InputBundle {
        let days = (27...29).map { day in
            DailyInput(date: "2026-09-\(day)", sourceKey: "synthetic-presentation",
                       dayDurationSeconds: 86400, elapsedSeconds: day == 29 ? 43200 : 86400,
                       isClosed: day < 29,
                       heartRateBins: day == 29 ? [] : [.init(bpm: day == 28 ? 80 : 120, seconds: 86400)],
                       rmssdMs: 40, restingHeartRate: 60,
                       sleep: .init(asleepMinutes: 420, periodMinutes: 480, midpointMinute: 180),
                       issues: day == 29 ? issue.map { [$0] } ?? [] : [],
                       oxygenSaturationPercent: 97, respiratoryRateBrpm: 15, skinTemperatureCelsius: 33)
        }
        return InputBundle(generatedAt: "2026-09-29T12:00:00Z", asOfDate: "2026-09-29",
                           ageYears: 40, measuredMaxHeartRate: 200, days: days)
    }

    private var vitalMetrics: [FormMetric] { [.hrv, .restingHR, .oxygen, .breathing, .temperature] }

    @Test func refreshWarningNamesOnlyAffectedStreamsWithoutDuplicatingWindows() throws {
        let failures = try JSONDecoder().decode([MetricFailure].self, from: Data("""
        [{"metric":"daily-sleep-temperature-derivations","checkedAt":0,"code":"invalid_response"},
         {"metric":"daily-sleep-temperature-derivations","checkedAt":1,"code":"invalid_response"}]
        """.utf8))
        #expect(FormModel.refreshWarning(failures) == "Skin temperature couldn’t refresh. Any saved readings are still shown.")
        #expect(FormModel.refreshWarning([]) == nil)
    }

    @Test(arguments: ["rmssdMs", "restingHeartRate", "oxygenSaturationPercent", "respiratoryRateBrpm", "skinTemperatureCelsius"])
    func flaggedVitalIsUnavailableInDetailsAndTrends(field: String) throws {
        let mapping: [String: FormMetric] = ["rmssdMs": .hrv, "restingHeartRate": .restingHR,
            "oxygenSaturationPercent": .oxygen, "respiratoryRateBrpm": .breathing, "skinTemperatureCelsius": .temperature]
        let metric = try #require(mapping[field])
        for prefix in ["invalid_", "conflicting_"] {
            let model = FormModel(input: input(issue: prefix + field), mode: .imported, preview: true)
            #expect(model.value(metric, date: "2026-09-29") == nil)
            #expect(model.history(metric, count: 3).last?.value == nil)
            #expect(model.history(metric, count: 3).first?.value != nil)
            for other in vitalMetrics where other != metric {
                #expect(model.value(other, date: "2026-09-29") != nil)
            }
        }
    }

    @Test func unknownQualityIssueCannotReappearAsRawVitalNumbers() {
        let model = FormModel(input: input(issue: "unknown_quality_issue"), mode: .imported, preview: true)
        for metric in vitalMetrics {
            #expect(model.value(metric, date: "2026-09-29") == nil)
            #expect(model.history(metric, count: 3).last?.value == nil)
        }
        #expect(model.currentInsight?.sleep.asleepMinutes == nil)
    }

    @Test func missingHeartRateStaysMissingButObservedLowHeartRateIsRealZero() throws {
        let model = FormModel(input: input(), mode: .imported, preview: true)
        #expect(model.value(.strain, date: "2026-09-29") == nil)
        #expect(model.insight(for: "2026-09-29")?.activity.coverageFraction == nil)
        #expect(model.insight(for: "2026-09-29")?.activity.zoneMinutes == [])
        #expect(model.value(.strain, date: "2026-09-28") == 0)
        #expect(model.insight(for: "2026-09-28")?.activity.coverageFraction == 1)
        #expect(try #require(model.value(.strain, date: "2026-09-27")) > 0)
        let history = model.history(.strain, count: 3)
        #expect(history.map(\.value) == [1440, 0, nil])
    }

    @Test func replacingSameDateInvalidatesCachedInterpretation() throws {
        let model = FormModel(input: input(), mode: .imported, preview: true)
        #expect(model.value(.hrv, date: "2026-09-29") == 40)
        _ = model.currentInsight
        model.importCanonical(try JSONEncoder().encode(input(issue: "conflicting_rmssdMs")))
        #expect(model.value(.hrv, date: "2026-09-29") == nil)
        #expect(model.currentInsight?.vitals.first { $0.kind == .hrv }?.value == nil)
        #expect(model.value(.restingHR, date: "2026-09-29") == 60)
    }
}
