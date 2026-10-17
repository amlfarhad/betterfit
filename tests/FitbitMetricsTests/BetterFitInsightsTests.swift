#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
import Foundation
@testable import FitbitMetrics

final class BetterFitInsightsTests: MetricsTestBase {
    private func day(_ offset: Int = 0, closed: Bool = true, elevated: Double = 60,
                     source: String = "synthetic") -> DailyInput {
        let date = CivilDate("2026-09-28")!.adding(days: -offset).text
        return DailyInput(date: date, sourceKey: source, dayDurationSeconds: 86400,
                          elapsedSeconds: 86400, isClosed: closed,
                          heartRateBins: [.init(bpm: 100, seconds: elevated * 60),
                                          .init(bpm: 80, seconds: (1440 - elevated) * 60)],
                          rmssdMs: 40, restingHeartRate: 60,
                          sleep: .init(asleepMinutes: 420, periodMinutes: 480, midpointMinute: 180))
    }

    private func input(_ days: [DailyInput], asOf: String = "2026-09-29", target: Double = 480) -> InputBundle {
        InputBundle(generatedAt: "2026-09-29T18:00:00Z", asOfDate: asOf, ageYears: 40,
                    sleepTargetMinutes: target, measuredMaxHeartRate: 200, days: days)
    }

    private func insight(_ days: [DailyInput], date: String = "2026-09-28",
                         target: Double = 480) throws -> DailyInsight {
        let bundle = input(days, target: target)
        return try XCTUnwrap(BetterFitInsights.evaluate(input: bundle, scores: MetricsEngine.evaluate(bundle), date: date))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testObservedZonesRetainExactMinutesAndLegacyScore() throws {
        var selected = day()
        selected.heartRateBins = [80, 100, 120, 140, 160, 180].enumerated().map {
            HeartRateBin(bpm: Double($0.element), seconds: Double($0.offset + 1) * 60)
        }
        selected.heartRateBins[0].seconds += (1440 - 21) * 60
        let result = try insight([selected]).activity
        XCTAssertEqual(result.zoneMinutes, [1420, 2, 3, 4, 5, 6])
        XCTAssertEqual(result.elevatedMinutes, 20)
        XCTAssertEqual(result.higherIntensityMinutes, 15)
        XCTAssertEqual(result.observedMinutes, 1440)
        XCTAssertEqual(result.coverageFraction, 1)
        XCTAssertEqual(result.maxHeartRate, 200)
        XCTAssertEqual(result.maximumIsEstimated, false)
        XCTAssertEqual(try XCTUnwrap(result.legacyStrain), 21 * log1p(70.0 / 20) / log(31), accuracy: 1e-10)
        XCTAssertEqual(result.comparison, .buildingBaseline)
        XCTAssertTrue(result.headline.contains("Building"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testHighStrainIsAccumulatedLoadAndMappingRemainsUnchanged() throws {
        for score in [18.0, 18.5, 21.0] {
            let load = 20 * (pow(31, score / 21) - 1)
            let selected = day(elevated: load)
            let result = try insight([selected]).activity
            XCTAssertEqual(try XCTUnwrap(result.legacyStrain), score, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(result.elevatedMinutes), load, accuracy: 1e-9)
            XCTAssertTrue(!result.headline.lowercased().contains("danger"))
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testLivePartialDayNeverComparesLowWithCompletedDays() throws {
        var selected = day(-1, closed: false, elevated: 0)
        selected.elapsedSeconds = 3600
        selected.heartRateBins = [.init(bpm: 80, seconds: 3600)]
        let result = try insight([selected] + (0..<7).map { day($0) }, date: selected.date).activity
        XCTAssertEqual(result.comparison, .accumulating)
        XCTAssertEqual(result.elevatedMinutes, 0)
        XCTAssertEqual(result.baseline?.median, 60)
        XCTAssertTrue(result.headline.lowercased().contains("so far"))
        XCTAssertTrue(!result.headline.lowercased().contains("below"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testBaselineUsesPrior28DaysSameSourceAndFullCoverage() throws {
        var days = [day(elevated: 200)] + (1...7).map { day($0, elevated: Double($0 * 10)) }
        days += [day(8, elevated: 1000, source: "other"), day(29, elevated: 1000), day(-1, closed: false, elevated: 1000)]
        var incomplete = day(9, closed: false, elevated: 1000)
        days.append(incomplete)
        incomplete = day(10, elevated: 0)
        incomplete.heartRateBins = [.init(bpm: 100, seconds: 86400 * 0.89)]
        days.append(incomplete)
        let result = try insight(days).activity
        XCTAssertEqual(result.baseline?.sampleCount, 7)
        XCTAssertEqual(result.baseline?.median, 40)
        XCTAssertEqual(try XCTUnwrap(result.baseline?.lower), 16, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.baseline?.upper), 64, accuracy: 1e-9)
        XCTAssertEqual(result.comparison, .aboveUsual)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testMissingAndConflictingHeartRateNeverBecomeZero() throws {
        var selected = day()
        selected.heartRateBins = []
        let absent = try insight([selected]).activity
        XCTAssertEqual(absent.elevatedMinutes, nil)
        XCTAssertEqual(absent.coverageFraction, nil)
        XCTAssertEqual(absent.comparison, .unavailable)
        selected = day()
        selected.issues = ["conflicting_heart_rate"]
        let conflict = try insight([selected]).activity
        XCTAssertEqual(conflict.observedMinutes, nil)
        XCTAssertTrue(conflict.zoneMinutes.isEmpty)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testInsufficientCoverageShowsObservedMinutesWithoutFullDayComparison() throws {
        var selected = day()
        selected.heartRateBins = [.init(bpm: 100, seconds: 600)]
        let result = try insight([selected] + (1...7).map { day($0) }).activity
        XCTAssertEqual(result.elevatedMinutes, 10)
        XCTAssertEqual(result.legacyStrain, nil)
        XCTAssertEqual(result.comparison, .unavailable)
        XCTAssertTrue(result.headline.lowercased().contains("coverage"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testSleepDeficitUsesKnownNightsAndChosenTargetWithoutSurplusOffset() throws {
        var missing = day(2)
        missing.sleep = nil
        var surplus = day(3)
        surplus.sleep = .init(asleepMinutes: 600, periodMinutes: 620, midpointMinute: 180)
        let result = try insight([day(), day(1), missing, surplus, day(4, source: "other"), day(7)], target: 450).sleep
        XCTAssertEqual(result.knownNights, 3)
        XCTAssertEqual(result.windowNights, 7)
        XCTAssertEqual(result.deficitMinutes, 60)
        XCTAssertEqual(result.targetMinutes, 450)
        XCTAssertEqual(result.efficiencyPercent, 87.5)
        XCTAssertTrue(result.detail.contains("3 of 7"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testCompletedCurrentNightCountsButUnknownOrFutureEndDoesNot() throws {
        var selected = day(-1, closed: false)
        let unknown = try insight([selected], date: selected.date).sleep
        XCTAssertEqual(unknown.knownNights, 0)
        XCTAssertEqual(unknown.deficitMinutes, nil)
        selected.sleep?.startTime = "2026-09-29T00:00:00Z"
        selected.sleep?.endTime = "2026-09-29T08:00:00Z"
        let completed = try insight([selected], date: selected.date).sleep
        XCTAssertEqual(completed.knownNights, 1)
        XCTAssertEqual(completed.deficitMinutes, 60)
        selected.sleep?.endTime = "2026-09-29T20:00:00Z"
        XCTAssertEqual(try insight([selected], date: selected.date).sleep.deficitMinutes, nil)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testSleepRegularityWrapsMidnightAndRequiresSevenPriorNights() throws {
        var days = (0...7).map { day($0) }
        for i in days.indices { days[i].sleep?.midpointMinute = i == 0 ? 5 : 1435 }
        let result = try insight(days).sleep
        XCTAssertEqual(try XCTUnwrap(result.midpointDeviationMinutes), 10, accuracy: 1e-9)
        XCTAssertEqual(result.priorNights, 7)
        days.removeLast()
        XCTAssertEqual(try insight(days).sleep.midpointDeviationMinutes, nil)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testVitalPersonalRangesExcludeSelectedDateAndPreserveNativeUnits() throws {
        var days = (0...7).map { day($0) }
        for index in days.indices {
            days[index].oxygenSaturationPercent = index == 0 ? 94 : 97
            days[index].respiratoryRateBrpm = index == 0 ? 16 : 15
            days[index].skinTemperatureCelsius = index == 0 ? 34 : 33
        }
        let vitals = try insight(days).vitals
        let oxygen = try XCTUnwrap(vitals.first { $0.kind == .oxygenSaturation })
        XCTAssertEqual(oxygen.value, 94)
        XCTAssertEqual(oxygen.unit, "%")
        XCTAssertEqual(oxygen.baseline?.median, 97)
        XCTAssertEqual(oxygen.baseline?.sampleCount, 7)
        XCTAssertEqual(oxygen.deviation, -3)
        XCTAssertEqual(oxygen.comparison, .belowUsual)
        XCTAssertEqual(oxygen.headline, "Below your usual range")
        XCTAssertEqual(vitals.first { $0.kind == .skinTemperature }?.deviation, 1)
        XCTAssertEqual(vitals.first { $0.kind == .respiratoryRate }?.unit, "br/min")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testEachVitalHasIndependentBaselineAndMissingIsNotImputed() throws {
        var days = (0...7).map { day($0) }
        days[7].rmssdMs = nil
        days[0].oxygenSaturationPercent = nil
        let vitals = try insight(days).vitals
        XCTAssertEqual(vitals.first { $0.kind == .hrv }?.comparison, .buildingBaseline)
        XCTAssertEqual(vitals.first { $0.kind == .restingHeartRate }?.comparison, .withinUsual)
        XCTAssertEqual(vitals.first { $0.kind == .oxygenSaturation }?.value, nil)
        XCTAssertEqual(vitals.first { $0.kind == .oxygenSaturation }?.comparison, .unavailable)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testIdenticalDecimalReadingsNeverBecomeBelowOrAboveTheirOwnRange() throws {
        for count in [14, 22] {
            var days = (0...count).map { day($0) }
            for index in days.indices {
                days[index].oxygenSaturationPercent = 98.7
                days[index].rmssdMs = 42.6
            }
            let vitals = try insight(days).vitals
            XCTAssertEqual(vitals.first { $0.kind == .oxygenSaturation }?.comparison, .withinUsual)
            XCTAssertEqual(vitals.first { $0.kind == .hrv }?.comparison, .withinUsual)
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testKnownIssueOnlyBlocksAffectedVitalAndUnknownIssueBlocksAll() throws {
        var days = (0...7).map { day($0) }
        days[0].oxygenSaturationPercent = 97
        days[0].issues = ["invalid_oxygenSaturationPercent"]
        var result = try insight(days)
        XCTAssertEqual(result.vitals.first { $0.kind == .oxygenSaturation }?.value, nil)
        XCTAssertEqual(result.vitals.first { $0.kind == .hrv }?.value, 40)
        XCTAssertEqual(result.activity.elevatedMinutes, 60)
        days[0].issues = ["unknown_quality_issue"]
        result = try insight(days)
        XCTAssertTrue(result.vitals.allSatisfy { $0.value == nil })
        XCTAssertEqual(result.activity.elevatedMinutes, nil)
        XCTAssertEqual(result.sleep.asleepMinutes, nil)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStageQualityIssuesLeaveUnrelatedHeartRateAndVitalsAvailable() throws {
        var selected = day()
        selected.issues = ["invalid_sleep_stages"]
        selected.sleep?.lightMinutes = 100
        let result = try insight([selected])
        XCTAssertEqual(result.sleep.asleepMinutes, selected.sleep?.asleepMinutes)
        XCTAssertEqual(result.sleep.lightMinutes, nil)
        XCTAssertEqual(result.activity.elevatedMinutes, 60)
        XCTAssertEqual(result.vitals.first { $0.kind == .hrv }?.value, 40)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testCompletedSleepAcceptsCanonicalFractionalTimestamps() throws {
        var selected = day(-1, closed: false)
        selected.sleep?.startTime = "2026-09-29T00:00:00.123456789Z"
        selected.sleep?.endTime = "2026-09-29T08:00:00.123456789Z"
        let result = try insight([selected], date: selected.date).sleep
        XCTAssertEqual(result.knownNights, 1)
        XCTAssertEqual(result.deficitMinutes, 60)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testInsightsAreDeterministicAndDoNotDependOnInputOrder() throws {
        var days = (0...7).map { day($0) }
        for index in days.indices { days[index].sleep?.asleepMinutes = [479.9, 17.1234567, 398.55555, 477.8][index % 4] }
        let first = try insight(days)
        let second = try insight(Array(days.reversed()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        let bundle = input(days)
        XCTAssertTrue(BetterFitInsights.evaluate(input: bundle, scores: try MetricsEngine.evaluate(bundle), date: "2020-01-01") == nil)
    }
}
