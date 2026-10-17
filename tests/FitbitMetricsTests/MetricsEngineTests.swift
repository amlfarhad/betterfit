#if canImport(XCTest)
import XCTest
typealias MetricsTestBase = XCTestCase
#else
import Testing
#endif
import Foundation
@testable import FitbitMetrics

final class MetricsEngineTests: MetricsTestBase {
    func day(_ date: String = "2026-09-28", steps: Any = 8000, coverage: Double = 1,
             source: String = "air", hrv: Any = 40, rhr: Any = 60,
             asleep: Double = 480, period: Double = 510, midpoint: Double = 180,
             duration: Double = 86400, closed: Bool = true,
             issues: [String] = [], complete: Bool = true) -> [String: Any] {
        ["date": date, "sourceKey": source, "dayDurationSeconds": duration,
         "elapsedSeconds": duration, "isClosed": closed, "steps": steps,
         "stepsComplete": complete, "heartRateBins": [["bpm": 80.0, "seconds": duration * coverage]],
         "rmssdMs": hrv, "restingHeartRate": rhr,
         "sleep": ["asleepMinutes": asleep, "periodMinutes": period, "midpointMinute": midpoint],
         "issues": issues]
    }

    func bundle(_ days: [[String: Any]], age: Any = 40, asOf: String = "2026-09-29") -> [String: Any] {
        ["schemaVersion": 1, "generatedAt": "2026-09-29T18:00:00Z", "asOfDate": asOf,
         "ageYears": age, "sleepTargetMinutes": 480, "measuredMaxHeartRate": 200, "days": days]
    }

    func evaluate(_ input: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: input)
        let output = try MetricsEngine.evaluate(json: data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    func score(_ output: [String: Any], _ name: String, date: String? = nil) throws -> [String: Any] {
        if name == "biologicalAge" {
            let age = try XCTUnwrap(output[name] as? [String: Any])
            return try XCTUnwrap(age["score"] as? [String: Any])
        }
        let days = try XCTUnwrap(output["days"] as? [[String: Any]])
        let selected = date.flatMap { date in days.first { $0["date"] as? String == date } } ?? days.last
        return try XCTUnwrap(selected?[name] as? [String: Any])
    }

    func number(_ score: [String: Any], _ key: String = "value") throws -> Double {
        try XCTUnwrap(score[key] as? Double)
    }

    func history(_ count: Int, steps: [Double]? = nil) -> [[String: Any]] {
        (0..<count).map { index in day(String(format: "2026-09-%02d", 28 - index),
                                     steps: steps?[index] ?? 8000) }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testSleepGoldenAndExplicitNullMissing() throws {
        let output = try evaluate(bundle([day(asleep: 360, period: 480)]))
        XCTAssertEqual(try number(score(output, "sleep")), 76.66666666666667, accuracy: 1e-9)
        var missing = day(); missing["sleep"] = NSNull()
        let result = try score(evaluate(bundle([missing])), "sleep")
        XCTAssertTrue(result["value"] is NSNull)
        XCTAssertEqual(result["status"] as? String, "unavailable")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testSleepZeroAndAboveTargetCap() throws {
        XCTAssertEqual(try number(score(evaluate(bundle([day(asleep: 0)])), "sleep")), 0)
        XCTAssertEqual(try number(score(evaluate(bundle([day(asleep: 600, period: 620)])), "sleep")), 100)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStrainZoneBoundariesAndDisplayGolden() throws {
        var d = day(duration: 86400)
        d["heartRateBins"] = [99, 100, 120, 140, 160, 180].map { ["bpm": Double($0), "seconds": 14400.0] }
        let result = try score(evaluate(bundle([d])), "strain")
        let components = try XCTUnwrap(result["components"] as? [String: Double])
        XCTAssertEqual(components["rawLoad"], 3600)
        XCTAssertEqual(try number(result), 21)
        d["heartRateBins"] = [["bpm": 100, "seconds": 600], ["bpm": 80, "seconds": 85800]]
        XCTAssertEqual(try number(score(evaluate(bundle([d])), "strain")), 2.4795570755622722, accuracy: 1e-9)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStrainCoverageThresholdsAndLiveStatus() throws {
        for (coverage, status) in [(0.79999, "insufficientCoverage"), (0.8, "partial"), (0.89999, "partial"), (0.9, "available")] {
            let result = try score(evaluate(bundle([day(coverage: coverage)])), "strain")
            XCTAssertEqual(result["status"] as? String, status)
            if coverage < 0.8 { XCTAssertTrue(result["value"] is NSNull) }
        }
        let result = try score(evaluate(bundle([day("2026-09-29", closed: false)])), "strain")
        XCTAssertEqual(result["status"] as? String, "live")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testEmptyHeartRateNeverBecomesZero() throws {
        var d = day(); d["heartRateBins"] = []
        let result = try score(evaluate(bundle([d])), "strain")
        XCTAssertTrue(result["value"] is NSNull)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryCalibrationAndZeroMADFloor() throws {
        var days = history(7)
        XCTAssertEqual(try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")["status"] as? String, "calibrating")
        days += [day("2026-09-21")]
        let recovered = try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")
        XCTAssertEqual(try number(recovered), 70, accuracy: 1e-9)
        XCTAssertEqual(recovered["status"] as? String, "provisional")
        days[0]["rmssdMs"] = 40 * exp(0.1)
        days[0]["restingHeartRate"] = 57
        XCTAssertEqual(try number(score(evaluate(bundle(days)), "recovery", date: "2026-09-28")), 80, accuracy: 1e-9)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryMatureAndOutlierClampsAndSleepPenalty() throws {
        var days = history(22)
        days[0]["rmssdMs"] = 4000
        days[0]["restingHeartRate"] = 30
        days[0]["sleep"] = ["asleepMinutes": 240, "periodMinutes": 300, "midpointMinute": 180]
        let result = try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")
        XCTAssertEqual(try number(result), 90, accuracy: 1e-9)
        XCTAssertEqual(result["status"] as? String, "available")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryBaselineExcludesFutureSourceAndUnpairedValues() throws {
        var days = history(8)
        days[7]["sourceKey"] = "other"
        days += [day("2026-09-29", hrv: 4000, closed: false)]
        XCTAssertEqual(try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")["status"] as? String, "calibrating")
        days[7]["sourceKey"] = "air"; days[7]["restingHeartRate"] = NSNull()
        XCTAssertEqual(try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")["status"] as? String, "calibrating")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRegularityCircularMidnightAndSevenPriorGate() throws {
        var days = history(8)
        for i in 1..<8 { days[i]["sleep"] = ["asleepMinutes": 480, "periodMinutes": 510, "midpointMinute": 1435] }
        days[0]["sleep"] = ["asleepMinutes": 480, "periodMinutes": 510, "midpointMinute": 5]
        let result = try score(evaluate(bundle(days)), "sleepRegularity", date: "2026-09-28")
        XCTAssertEqual(try number(result), 100 * exp(-0.5 * pow(10.0 / 60, 2)), accuracy: 1e-9)
        days.removeLast()
        XCTAssertTrue(try score(evaluate(bundle(days)), "sleepRegularity", date: "2026-09-28")["value"] is NSNull)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAgePublishedEquationGoldenAndSampleSDSensitivity() throws {
        let days = history(7, steps: [1000, 2000, 3000, 4000, 5000, 6000, 7000])
        let result = try score(evaluate(bundle(days)), "biologicalAge")
        let expected = 4.2390852 + 1.0824163 * 40 - 0.0012294 * 7000 + 0.0015739 * sqrt(28_000_000.0 / 6)
        XCTAssertEqual(try number(result), expected, accuracy: 1e-9)
        let components = try XCTUnwrap(result["components"] as? [String: Double])
        XCTAssertEqual(components["sampleSDDailySteps"]!, 2160.2468994692867, accuracy: 1e-9)
        XCTAssertNotEqual(try number(result), 4.2390852 + 1.0824163 * 40 - 0.0012294 * 7000 + 0.0015739 * 2000)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAgeSameMaximumHigherVariabilityIncreasesEstimate() throws {
        let stable = try number(score(evaluate(bundle(history(7, steps: [7000,7000,7000,7000,7000,7000,7000]))), "biologicalAge"))
        let variable = try number(score(evaluate(bundle(history(7, steps: [0,0,0,0,0,0,7000]))), "biologicalAge"))
        XCTAssertGreaterThan(variable, stable)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAgeRequiresExactPreviousSevenDaysAndReportsCollection() throws {
        var days = history(7); days[3]["date"] = "2026-09-01"
        let output = try evaluate(bundle(days))
        XCTAssertTrue(try score(output, "biologicalAge")["value"] is NSNull)
        let age = try XCTUnwrap(output["biologicalAge"] as? [String: Any])
        let collection = try XCTUnwrap(age["collection"] as? [String: Any])
        XCTAssertEqual(collection["eligibleDays"] as? Int, 6)
        XCTAssertEqual(collection["windowStart"] as? String, "2026-09-22")
        XCTAssertEqual(collection["windowEnd"] as? String, "2026-09-28")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAgeGatesCoverageCompleteIssuesAndSource() throws {
        for change: [String: Any] in [
            ["steps": NSNull()], ["stepsComplete": false], ["sourceKey": "other"],
            ["heartRateBins": [["bpm": 80, "seconds": 0.8999 * 86400]]], ["issues": ["timezoneConflict"]], ["isClosed": false]
        ] {
            var days = history(7)
            days[0].merge(change) { _, replacement in replacement }
            XCTAssertTrue(try score(evaluate(bundle(days)), "biologicalAge")["value"] is NSNull, "change: \(change)")
        }
        XCTAssertNotNil(try score(evaluate(bundle(history(7).map { original in
            var d = original; d["heartRateBins"] = [["bpm": 80, "seconds": 0.9 * 86400]]; return d
        })), "biologicalAge")["value"] as? Double)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAgeDomainWithoutClamping() throws {
        for age in [0, 19.99] {
            let result = try score(evaluate(bundle(history(7), age: age)), "biologicalAge")
            XCTAssertEqual(result["status"] as? String, "outOfDomain")
            XCTAssertTrue(result["value"] is NSNull)
        }
        for age in [20, 85, 90] { XCTAssertNotNil(try score(evaluate(bundle(history(7), age: age)), "biologicalAge")["value"] as? Double) }
        let result = try score(evaluate(bundle(history(7, steps: Array(repeating: 100000.0, count: 7)))), "biologicalAge")
        XCTAssertEqual(result["status"] as? String, "outOfDomain")
        XCTAssertTrue(result["value"] is NSNull)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testDSTDurationsUseProvidedElapsedSeconds() throws {
        for hours in [23.0, 25.0] {
            let result = try score(evaluate(bundle([day(duration: hours * 3600)])), "strain")
            let components = try XCTUnwrap(result["components"] as? [String: Double])
            XCTAssertEqual(components["coverage"], 1)
            XCTAssertEqual(result["status"] as? String, "available")
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testAllMissingRetainsNullsAndCollectionProgress() throws {
        var d = day(steps: NSNull(), hrv: NSNull(), rhr: NSNull(), complete: false)
        d["sleep"] = NSNull(); d["heartRateBins"] = []
        let result = try evaluate(bundle([d]))
        for name in ["sleep", "strain", "recovery", "sleepRegularity", "biologicalAge"] {
            XCTAssertTrue(try score(result, name)["value"] is NSNull, name)
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStrictBundleValidation() throws {
        var inputs: [[String: Any]] = []
        for (key, value): (String, Any) in [("schemaVersion", 2), ("asOfDate", "2026-02-30"), ("generatedAt", "not-a-date"), ("ageYears", -1), ("sleepTargetMinutes", 0), ("measuredMaxHeartRate", 0)] {
            var input = bundle([]); input[key] = value; inputs.append(input)
        }
        for (key, value): (String, Any) in [("date", "2026-02-30"), ("date", "2026-9-28"), ("date", "2026-09-30"), ("sourceKey", ""), ("steps", -1), ("rmssdMs", 0), ("restingHeartRate", -1), ("elapsedSeconds", 90000), ("dayDurationSeconds", 0), ("heartRateBins", [["bpm": 80, "seconds": 86401]]), ("heartRateBins", [["bpm": 0, "seconds": 60]]), ("heartRateBins", [["bpm": 80, "seconds": -1]])] {
            var d = day(); d[key] = value; inputs.append(bundle([d]))
        }
        inputs += [bundle([day(), day()]), bundle([day("2026-09-29")]), bundle([day(asleep: 481, period: 480)]), bundle([day(period: 0)]), bundle([day(period: 1441)]), bundle([day(midpoint: 1440)])]
        for input in inputs { XCTAssertThrowsError(try evaluate(input), "invalid input accepted: \(input)") }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testSchemaMetadataAndDeterministicSorting() throws {
        let result = try evaluate(bundle([day("2026-09-28"), day("2026-09-27")]))
        XCTAssertEqual(result["schemaVersion"] as? Int, 1)
        XCTAssertEqual((result["days"] as? [[String: Any]])?.first?["date"] as? String, "2026-09-27")
        XCTAssertNotNil(result["modelVersions"])
        XCTAssertNotNil(result["diagnostics"])
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testIndependentAgeGoldens() throws {
        XCTAssertEqual(try number(score(evaluate(bundle(history(7))), "biologicalAge")), 37.7005372, accuracy: 1e-9)
        let steps: [Double] = [2000, 4000, 6000, 8000, 10000, 12000, 14000]
        XCTAssertEqual(try number(score(evaluate(bundle(history(7, steps: steps))), "biologicalAge")), 37.12416239014942, accuracy: 1e-9)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testMalformedAndNonfiniteJSONIsRejected() throws {
        for value in ["NaN", "Infinity", "1e309", "\"NaN\""] {
            let input = "{\"schemaVersion\":1,\"generatedAt\":\"2026-09-29T18:00:00Z\",\"asOfDate\":\"2026-09-29\",\"ageYears\":\(value),\"days\":[]}"
            XCTAssertThrowsError(try MetricsEngine.evaluate(json: Data(input.utf8)))
        }
        XCTAssertThrowsError(try MetricsEngine.evaluate(json: Data("{bad}".utf8)))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStrainPartitionInvarianceAndEstimatedMaximum() throws {
        var d = day()
        d["heartRateBins"] = [["bpm": 110, "seconds": 86400]]
        let first = try score(evaluate(bundle([d])), "strain")
        d["heartRateBins"] = Array(repeating: ["bpm": 110, "seconds": 60], count: 1440)
        let second = try score(evaluate(bundle([d])), "strain")
        XCTAssertEqual(try number(first), try number(second), accuracy: 1e-9)
        var input = bundle([d]); input.removeValue(forKey: "measuredMaxHeartRate")
        let result = try score(evaluate(input), "strain")
        XCTAssertTrue((result["reasons"] as? [String])?.contains("estimatedMaxHeartRate") == true)
        XCTAssertEqual((result["components"] as? [String: Double])?["maxHeartRate"], 180)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryWindowIncludes28thPriorDateOnly() throws {
        var days = history(7)
        days += [day("2026-08-31")]
        XCTAssertEqual(try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")["status"] as? String, "provisional")
        days[7]["date"] = "2026-08-30"
        XCTAssertEqual(try score(evaluate(bundle(days)), "recovery", date: "2026-09-28")["status"] as? String, "calibrating")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testDefaultSleepTargetAndFractionalCaptureTimestamp() throws {
        var input = bundle([day()]); input.removeValue(forKey: "sleepTargetMinutes")
        input["generatedAt"] = "2026-09-29T18:00:00.123456Z"
        XCTAssertEqual(try number(score(evaluate(input), "sleep")), 100)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testCurrentDayCoverageUsesElapsedTime() throws {
        var d = day("2026-09-29", closed: false)
        d["elapsedSeconds"] = 1000
        d["heartRateBins"] = [["bpm": 80, "seconds": 900]]
        let result = try score(evaluate(bundle([d])), "strain")
        XCTAssertEqual(result["status"] as? String, "live")
        XCTAssertEqual((result["components"] as? [String: Double])?["coverage"], 0.9)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testClosedDayRequiresFullElapsedDuration() throws {
        var d = day(); d["elapsedSeconds"] = 1000
        d["heartRateBins"] = [["bpm": 80, "seconds": 1000]]
        XCTAssertThrowsError(try evaluate(bundle([d])))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testUnclosedHistoricalDayCannotBeLive() throws {
        let result = try score(evaluate(bundle([day(closed: false)])), "strain")
        XCTAssertEqual(result["status"] as? String, "partial")
        XCTAssertTrue((result["reasons"] as? [String])?.contains("historicalDayNotClosed") == true)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStrictTimestampAndNativeNonfiniteValues() throws {
        for timestamp in ["2026-02-30T10:00:00Z", "2026-09-29T25:00:00Z", "2026-09-29T18:61:00Z", "2026-09-29T18:00:61Z", "2026-09-29T18:00:00+00:00"] {
            var input = bundle([]); input["generatedAt"] = timestamp
            XCTAssertThrowsError(try evaluate(input))
        }
        var native = InputBundle(generatedAt: "2026-09-29T18:00:00Z", asOfDate: "2026-09-29", ageYears: .nan, days: [])
        XCTAssertThrowsError(try MetricsEngine.evaluate(native))
        native.ageYears = 40
        native.days = [DailyInput(date: "2026-09-28", sourceKey: "air", dayDurationSeconds: 86400,
                                 elapsedSeconds: 86400, isClosed: true, steps: .infinity)]
        XCTAssertThrowsError(try MetricsEngine.evaluate(native))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testLargeFiniteStepsProduceOutOfDomainWithoutNaN() throws {
        let input = bundle(history(7, steps: [1e308,1e308,0,0,0,0,0]))
        let result = try score(evaluate(input), "biologicalAge")
        XCTAssertTrue(result["value"] is NSNull)
        XCTAssertEqual(result["status"] as? String, "outOfDomain")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testBiologicalAgeWindowAcrossYearBoundary() throws {
        let dates = ["2025-12-26", "2025-12-27", "2025-12-28", "2025-12-29", "2025-12-30", "2025-12-31", "2026-01-01"]
        let result = try score(evaluate(bundle(dates.map { day($0) }, asOf: "2026-01-02")), "biologicalAge")
        XCTAssertEqual(try number(result), 37.7005372, accuracy: 1e-9)
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRecoveryUnaffectedByLaterMeasurementsOrInputOrder() throws {
        let prior = history(8)
        let first = try score(evaluate(bundle(prior)), "recovery", date: "2026-09-28")
        let changed = Array(prior.reversed()) + [day("2026-09-29", hrv: 1, rhr: 200, closed: false)]
        let second = try score(evaluate(bundle(changed)), "recovery", date: "2026-09-28")
        XCTAssertEqual(try number(first), try number(second))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testRelevantSourceIssuesWithholdScores() throws {
        for issue in ["timezone_offset_mismatch", "future_observation", "unknown_issue"] {
            let result = try evaluate(bundle([day(issues: [issue])]))
            for name in ["sleep", "sleepRegularity", "recovery", "strain"] {
                XCTAssertTrue(try score(result, name)["value"] is NSNull)
                XCTAssertEqual(try score(result, name)["status"] as? String, "unavailable")
            }
        }
        for issue in ["invalid_heart_rate", "conflicting_heart_rate"] {
            let result = try evaluate(bundle([day(issues: [issue])]))
            XCTAssertTrue(try score(result, "strain")["value"] is NSNull)
            XCTAssertNotNil(try score(result, "sleep")["value"] as? Double)
        }
        for issue in ["invalid_sleep", "multiple_main_sleeps"] {
            let result = try evaluate(bundle([day(issues: [issue])]))
            XCTAssertTrue(try score(result, "sleep")["value"] is NSNull)
            XCTAssertNotNil(try score(result, "strain")["value"] as? Double)
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testFlaggedOrUnclosedNightsDoNotMatureBaselines() throws {
        for issue in ["invalid_sleep", "multiple_main_sleeps", "invalid_rmssdMs", "conflicting_rmssdMs", "invalid_restingHeartRate", "conflicting_restingHeartRate", "timezone_offset_mismatch"] {
            var days = history(8); days[7]["issues"] = [issue]
            let output = try evaluate(bundle(days))
            XCTAssertEqual(try score(output, "recovery", date: "2026-09-28")["status"] as? String, "calibrating", issue)
        }
        var days = history(8); days[7]["isClosed"] = false
        let output = try evaluate(bundle(days))
        XCTAssertEqual(try score(output, "recovery", date: "2026-09-28")["status"] as? String, "calibrating")
        XCTAssertEqual(try score(output, "sleepRegularity", date: "2026-09-28")["status"] as? String, "calibrating")
        days[7]["isClosed"] = true; days[7]["issues"] = ["invalid_sleep"]
        XCTAssertEqual(try score(evaluate(bundle(days)), "sleepRegularity", date: "2026-09-28")["status"] as? String, "calibrating")
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testStepIssuesDoNotWithholdUnrelatedScores() throws {
        for issue in ["invalid_steps", "overlapping_steps"] {
            var days = history(8)
            for index in days.indices { days[index]["issues"] = [issue] }
            let output = try evaluate(bundle(days))
            for name in ["sleep", "sleepRegularity", "recovery", "strain"] {
                XCTAssertNotNil(try score(output, name, date: "2026-09-28")["value"] as? Double)
            }
            XCTAssertTrue(try score(output, "biologicalAge")["value"] is NSNull)
        }
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testCoverageThresholdsAreStableUnderFractionalPartitioning() throws {
        for (coverage, expected) in [(0.8, "partial"), (0.9, "available")] {
            var d = day()
            d["heartRateBins"] = Array(repeating: ["bpm": 80.0, "seconds": 86400 * coverage / 1000], count: 1000)
            let result = try score(evaluate(bundle([d])), "strain")
            XCTAssertEqual(result["status"] as? String, expected)
        }
        let days = history(7).map { original in
            var d = original
            d["heartRateBins"] = Array(repeating: ["bpm": 80.0, "seconds": 77760.0 / 1000], count: 1000)
            return d
        }
        XCTAssertNotNil(try score(evaluate(bundle(days)), "biologicalAge")["value"] as? Double)
    }
}
