import SwiftUI
import WidgetKit

private enum BetterFitPalette {
    static let graphite = Color(red: 16 / 255, green: 20 / 255, blue: 22 / 255)
    static let ivory = Color(red: 242 / 255, green: 240 / 255, blue: 233 / 255)
    static let secondary = Color(red: 157 / 255, green: 165 / 255, blue: 167 / 255)
    static func tint(for metric: WidgetMetric) -> Color {
        switch metric {
        case .recovery: Color(red: 214 / 255, green: 245 / 255, blue: 139 / 255)
        case .activity: Color(red: 141 / 255, green: 203 / 255, blue: 236 / 255)
        case .sleep: Color(red: 183 / 255, green: 165 / 255, blue: 238 / 255)
        }
    }
}

struct FormEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct FormProvider: TimelineProvider {
    func placeholder(in context: Context) -> FormEntry { FormEntry(date: .now, snapshot: .empty) }

    func getSnapshot(in context: Context, completion: @escaping (FormEntry) -> Void) {
        completion(FormEntry(date: .now, snapshot: loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FormEntry>) -> Void) {
        let now = Date.now
        let snapshot = loadSnapshot()
        // Precomputed entries age the saved reading even if a later reload is deferred.
        // No entry fetches data or changes a score; WidgetKit controls actual scheduling.
        let entries = (0...48).map { offset in
            FormEntry(date: now.addingTimeInterval(Double(offset) * 30 * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private func loadSnapshot() -> WidgetSnapshot {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return .empty }
        let url = container.appendingPathComponent("widget-snapshot.json", isDirectory: false)
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...65_536).contains(size) else { return .empty }
            return try WidgetSnapshot.decode(Data(contentsOf: url))
        } catch {
            // Protected data may be unavailable while locked; never fabricate a score.
            return .empty
        }
    }
}

/// Shared presentation keeps the same state wording on the Home and Lock Screens.
private struct WidgetReading {
    let entry: FormEntry
    let metric: WidgetMetric

    var value: Double? { entry.snapshot.value(for: metric) }
    var state: WidgetMetricState { entry.snapshot.state(for: metric, at: entry.date) }
    var number: String { value?.formatted(.number.precision(.fractionLength(0))) ?? "—" }
    var compactNumber: String { number + (metric == .activity && value != nil ? "m" : "") }
    var progress: Double? {
        guard state != .stale && state != .partial else { return nil }
        return entry.snapshot.progress(for: metric)
    }
    var caption: String {
        guard metric == .activity, value != nil else { return state.label }
        switch state {
        case .ready, .live:
            return progress == nil ? "Observed minutes" : "vs usual day"
        default: return state.label
        }
    }
    var circularCaption: String {
        if metric == .activity, value != nil, state == .ready || state == .live {
            return progress == nil ? "MINUTES" : "USUAL DAY"
        }
        return state.shortLabel
    }
    var accessibility: String {
        var text = "\(metric.title): "
        if let value {
            text += "\(value.formatted(.number.precision(.fractionLength(0)))) \(metric == .activity ? "observed higher-heart-rate minutes" : "out of 100"). \(state.label). "
        } else { text += "\(state.label). " }
        if metric == .activity {
            if let reference = entry.snapshot.activityBaselineMinutes {
                text += "Usual completed day: \(Int(reference.rounded())) minutes. The ring is a comparison, not a goal or limit. "
            } else { text += "Usual-day baseline is still collecting. " }
            if let coverage = entry.snapshot.activityCoverage { text += "Heart-rate coverage \(Int((coverage * 100).rounded())) percent. " }
        }
        return text + entry.snapshot.provenanceLabel(at: entry.date)
    }
}

private struct ReadingRing: View {
    let progress: Double?
    let tint: Color
    var width: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), style: StrokeStyle(lineWidth: width, dash: progress == nil ? [2, 4] : []))
            if let progress, progress > 0 {
                Circle().trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(width / 2)
        .accessibilityHidden(true)
    }
}

struct FormWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FormEntry

    var body: some View {
        Group {
            if family == .systemSmall { small }
            else { medium }
        }
        .foregroundStyle(BetterFitPalette.ivory)
        .containerBackground(for: .widget) { BetterFitPalette.graphite }
        .widgetURL(WidgetMetric.recovery.deepLink)
        .privacySensitive()
    }

    private var small: some View {
        let reading = WidgetReading(entry: entry, metric: .recovery)
        return VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 3)
            HStack(alignment: .center, spacing: 6) {
                Text(reading.number)
                    .font(.custom("AvenirNext-UltraLight", size: 55, relativeTo: .largeTitle))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                ReadingRing(progress: reading.progress, tint: BetterFitPalette.tint(for: .recovery))
                    .overlay { Image(systemName: WidgetMetric.recovery.symbol).font(.system(size: 13)).foregroundStyle(BetterFitPalette.tint(for: .recovery)) }
                    .frame(width: 48, height: 48)
            }
            Text("RECOVERY")
                .font(.custom("AvenirNext-DemiBold", size: 10, relativeTo: .caption2))
                .tracking(1.5)
                .foregroundStyle(BetterFitPalette.tint(for: .recovery))
            Text(reading.caption)
                .font(.custom("AvenirNext-Regular", size: 10, relativeTo: .caption2))
                .foregroundStyle(BetterFitPalette.secondary)
                .padding(.top, 2)
            Spacer(minLength: 5)
            footer
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibility)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 9)
            HStack(alignment: .top, spacing: 14) {
                ForEach(WidgetMetric.allCases, id: \.self) { metric in
                    if metric != .recovery { Rectangle().fill(BetterFitPalette.ivory.opacity(0.1)).frame(width: 1, height: 64) }
                    homeMetric(metric)
                }
            }
            Spacer(minLength: 10)
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("BetterFit")
                .font(.custom("AvenirNext-DemiBold", size: 12, relativeTo: .caption))
            Spacer(minLength: 6)
            if entry.snapshot.isStale(at: entry.date) { Image(systemName: "clock").font(.system(size: 9)) }
            Text(entry.snapshot.measurementLabel)
                .font(.custom("AvenirNext-Medium", size: 10, relativeTo: .caption2))
                .foregroundStyle(BetterFitPalette.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var footer: some View {
        Text(entry.snapshot.provenanceLabel(at: entry.date))
            .font(.custom("AvenirNext-Medium", size: 9, relativeTo: .caption2))
            .foregroundStyle(BetterFitPalette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func homeMetric(_ metric: WidgetMetric) -> some View {
        let reading = WidgetReading(entry: entry, metric: metric)
        let tint = BetterFitPalette.tint(for: metric)
        return Link(destination: metric.deepLink) {
            VStack(alignment: .leading, spacing: 5) {
                Text(metric.title.uppercased())
                    .font(.custom("AvenirNext-DemiBold", size: 8, relativeTo: .caption2))
                    .tracking(0.7)
                    .foregroundStyle(tint)
                Text(reading.compactNumber)
                    .font(.custom("AvenirNext-UltraLight", size: 34, relativeTo: .title))
                    .monospacedDigit()
                GeometryReader { proxy in
                    Capsule().fill(tint.opacity(0.15))
                    if let progress = reading.progress, progress > 0 {
                        Capsule().fill(tint).frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
                Text(reading.caption)
                    .font(.custom("AvenirNext-Regular", size: 8, relativeTo: .caption2))
                    .foregroundStyle(BetterFitPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reading.accessibility)
        }
        .buttonStyle(.plain)
    }
}

struct BetterFitCircularView: View {
    let entry: FormEntry
    let metric: WidgetMetric

    var body: some View {
        let reading = WidgetReading(entry: entry, metric: metric)
        ZStack {
            ReadingRing(progress: reading.progress, tint: .primary)
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Image(systemName: metric.symbol)
                    if entry.snapshot.mode == .demo { Text("SAMPLE").font(.system(size: 6, weight: .semibold)) }
                    else if entry.snapshot.mode == .imported { Text("IMPORT").font(.system(size: 6, weight: .semibold)) }
                    else if reading.state == .stale { Image(systemName: "clock") }
                }
                .font(.system(size: 10, weight: .semibold))
                Text(reading.compactNumber)
                    .font(.system(size: 23, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text(reading.circularCaption)
                    .font(.system(size: 6, weight: .bold, design: .rounded))
                    .tracking(0.2)
                    .minimumScaleFactor(0.75)
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(metric.deepLink)
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.accessibility)
    }
}

struct BetterFitSummaryView: View {
    let entry: FormEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.snapshot.provenanceLabel(at: entry.date))
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
            HStack(alignment: .top, spacing: 8) {
                ForEach(WidgetMetric.allCases, id: \.self) { metric in
                    let reading = WidgetReading(entry: entry, metric: metric)
                    VStack(alignment: .leading, spacing: 1) {
                        Label(metric.title, systemImage: metric.symbol)
                            .font(.system(size: 7, weight: .medium))
                        Text(reading.compactNumber)
                            .font(.system(size: 20, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text(reading.state == .ready || reading.state == .live ? (metric == .activity ? "Observed" : "/ 100") : reading.state.shortLabel)
                            .font(.system(size: 6, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(reading.accessibility)
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "form://dashboard")!)
        .privacySensitive()
    }
}

@main
struct FormWidgets: WidgetBundle {
    var body: some Widget {
        FormDailyWidget()
        BetterFitRecoveryWidget()
        BetterFitActivityWidget()
        BetterFitSleepWidget()
        BetterFitSummaryWidget()
    }
}

struct FormDailyWidget: Widget {
    // Keep the existing kind so previously placed Home Screen widgets survive updates.
    let kind = "FormDaily"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FormProvider()) { FormWidgetView(entry: $0) }
            .configurationDisplayName("BetterFit daily")
            .description("Recovery, observed activity minutes, and sleep from your latest saved readings.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BetterFitRecoveryWidget: Widget {
    let kind = "BetterFitRecovery"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FormProvider()) { BetterFitCircularView(entry: $0, metric: .recovery) }
            .configurationDisplayName("Recovery")
            .description("Your recovery score out of 100, relative to your personal baseline. Open BetterFit for context.")
            .supportedFamilies([.accessoryCircular])
    }
}

struct BetterFitActivityWidget: Widget {
    let kind = "BetterFitActivity"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FormProvider()) { BetterFitCircularView(entry: $0, metric: .activity) }
            .configurationDisplayName("Activity")
            .description("Observed higher-heart-rate minutes, including daily movement. The ring compares with your usual completed day; it is not a goal or limit.")
            .supportedFamilies([.accessoryCircular])
    }
}

struct BetterFitSleepWidget: Widget {
    let kind = "BetterFitSleep"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FormProvider()) { BetterFitCircularView(entry: $0, metric: .sleep) }
            .configurationDisplayName("Sleep")
            .description("Your latest sleep score out of 100. Open BetterFit for sleep duration and available stages.")
            .supportedFamilies([.accessoryCircular])
    }
}

struct BetterFitSummaryWidget: Widget {
    let kind = "BetterFitSummary"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FormProvider()) { BetterFitSummaryView(entry: $0) }
            .configurationDisplayName("Daily summary")
            .description("A compact view of recovery, observed activity minutes, and sleep, with data source and measurement date.")
            .supportedFamilies([.accessoryRectangular])
    }
}
