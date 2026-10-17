import Foundation

@main
struct WidgetSnapshotTests {
    static func main() throws {
        let valid = #"{"generatedAt":"2026-09-29T12:00:00.123Z","measuredAt":"2026-09-29T10:00:00Z","date":"2026-09-29","mode":"connected","recovery":72,"recoveryStatus":"ready","strain":8.2,"strainStatus":"ready","sleep":null,"sleepStatus":"insufficient_data","age":null,"ageStatus":"collecting","ageCollectedDays":3}"#
        let snapshot = try WidgetSnapshot.decode(Data(valid.utf8))
        precondition(snapshot.recovery == 72)
        precondition(snapshot.strain == 8.2)
        precondition(snapshot.sleep == nil, "Missing scores remain missing")
        precondition(snapshot.mode == .connected)
        precondition(snapshot.measuredAt != nil)
        precondition(snapshot.measurementLabel == "Sep 29")

        let outOfRange = valid.replacingOccurrences(of: "\"recovery\":72", with: "\"recovery\":172")
            .replacingOccurrences(of: "\"strain\":8.2", with: "\"strain\":-1")
        let sanitized = try WidgetSnapshot.decode(Data(outOfRange.utf8))
        precondition(sanitized.recovery == nil && sanitized.strain == nil, "Do not present impossible cache values")
        for broken in [valid.replacingOccurrences(of: "connected", with: "unknown"), valid.replacingOccurrences(of: "2026-09-29T12:00:00.123Z", with: "not-a-date"), valid.replacingOccurrences(of: "\"date\":\"2026-09-29\"", with: "\"date\":\"2026-02-31\"")] {
            do {
                _ = try WidgetSnapshot.decode(Data(broken.utf8))
                preconditionFailure("Invalid snapshot accepted")
            } catch {}
        }
        let demo = try WidgetSnapshot.decode(Data(valid.replacingOccurrences(of: "connected", with: "demo").utf8))
        precondition(demo.sourceLabel == "SAMPLE DATA", "Demo must always be labeled")
        precondition(WidgetSnapshot.empty.recovery == nil && WidgetSnapshot.empty.mode == nil)
        precondition(WidgetSnapshot.empty.sourceLabel == "OPEN BETTERFIT", "The empty widget must name the installed app")

        let now = ISO8601DateFormatter().date(from: "2026-09-29T13:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        precondition(snapshot.activityMinutes == nil && snapshot.activityBaselineMinutes == nil && snapshot.activityCoverage == nil,
                     "Older snapshots decode without inventing activity minutes or a reference")
        precondition(snapshot.state(for: .sleep, at: now, calendar: calendar) == .missing)
        precondition(!snapshot.isStale(at: now, calendar: calendar))
        precondition(snapshot.isStale(at: now.addingTimeInterval(86_400), calendar: calendar), "Prior-day readings must not appear current")
        precondition(snapshot.isStale(at: now.addingTimeInterval(6 * 3_600), calendar: calendar), "Unrefreshed readings must be visibly stale")
        precondition(snapshot.isStale(at: now.addingTimeInterval(-4 * 3_600), calendar: calendar), "A future timestamp is not fresh")
        let previousDay = try decode(valid, changing: ["date": "2026-09-28"])
        precondition(previousDay.isStale(at: now, calendar: calendar), "Fresh save time cannot conceal an old measurement day")
        let oldMeasurement = try decode(valid, changing: ["measuredAt": "2026-09-28T10:00:00Z"])
        precondition(oldMeasurement.isStale(at: now, calendar: calendar), "A newly written cache cannot conceal old measurements")

        let activity = try decode(valid, changing: ["activityMinutes": 45, "activityBaselineMinutes": 60, "activityCoverage": 0.95, "strainStatus": "live"])
        precondition(activity.value(for: .activity) == 45 && activity.progress(for: .activity) == 0.75)
        precondition(activity.state(for: .activity, at: now, calendar: calendar) == .live)
        let aboveUsual = try decode(valid, changing: ["activityMinutes": 125, "activityBaselineMinutes": 60, "activityCoverage": 1])
        precondition(aboveUsual.value(for: .activity) == 125 && aboveUsual.progress(for: .activity) == 1,
                     "A ring may fill, but must never cap observed minutes or imply a safety ceiling")
        let noBaseline = try decode(valid, changing: ["activityMinutes": 45, "activityCoverage": 0.95])
        precondition(noBaseline.value(for: .activity) == 45 && noBaseline.progress(for: .activity) == nil,
                     "Observed minutes remain useful without an invented daily goal")
        let partial = try decode(valid, changing: ["activityMinutes": 12, "activityBaselineMinutes": 60, "activityCoverage": 0.4, "strainStatus": "insufficientCoverage"])
        precondition(partial.value(for: .activity) == 12 && partial.state(for: .activity, at: now, calendar: calendar) == .partial)
        precondition(partial.progress(for: .activity) == nil, "Partial data must not look like complete progress toward a usual day")
        let observedZero = try decode(valid, changing: ["activityMinutes": 0, "activityBaselineMinutes": 60, "activityCoverage": 1])
        precondition(observedZero.value(for: .activity) == 0 && observedZero.progress(for: .activity) == 0,
                     "A genuinely observed zero differs from absent data")
        let impossibleActivity = try decode(valid, changing: ["activityMinutes": -3, "activityBaselineMinutes": 0, "activityCoverage": 1.2])
        precondition(impossibleActivity.activityMinutes == nil && impossibleActivity.activityBaselineMinutes == nil && impossibleActivity.activityCoverage == nil)
        let calibrating = try decode(valid, changing: ["recovery": NSNull(), "recoveryStatus": "calibrating"])
        precondition(calibrating.state(for: .recovery, at: now, calendar: calendar) == .calibrating)
        let provisional = try decode(valid, changing: ["recoveryStatus": "provisional"])
        precondition(provisional.state(for: .recovery, at: now, calendar: calendar) == .provisional)
        precondition(activity.state(for: .activity, at: now.addingTimeInterval(86_400), calendar: calendar) == .stale)
        precondition(WidgetSnapshot.empty.state(for: .recovery, at: now, calendar: calendar) == .missing)
        precondition(demo.provenanceLabel(at: now.addingTimeInterval(86_400), calendar: calendar) == "Sample data",
                     "Synthetic scores are visibly identified at every widget size")
        precondition(WidgetMetric.activity.deepLink.absoluteString == "form://metric/strain", "Activity opens the existing metric route")
        print("Widget snapshot checks passed: legacy compatibility, bounds, provenance, stale dates, observed activity, reference rings, partial and calibrating states.")
    }

    static func decode(_ source: String, changing fields: [String: Any]) throws -> WidgetSnapshot {
        var value = try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any]
        value.merge(fields) { _, replacement in replacement }
        return try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: value))
    }
}
