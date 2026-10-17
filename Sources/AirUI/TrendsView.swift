import SwiftUI

struct TrendsView: View {
    @Bindable var model: FormModel
    @ViewState private var inspectedDate: String?
    @Environment(\.formStaticRendering) private var staticRendering
    var body: some View {
        // One history calculation per update, shared by the plot and every row.
        let points = model.history(model.trendMetric, count: model.trendDays)
        let averagePoints = model.trendMetric == .strain ? points.filter {
            guard let insight = model.insight(for: $0.date) else { return false }
            return insight.isClosed && (insight.activity.coverageFraction ?? 0) >= 0.9
        } : points
        let available = averagePoints.compactMap(\.value)
        let displayedValue = inspectedDate.map { selected in points.first { $0.date == selected }?.value }
            ?? (available.isEmpty ? nil : available.reduce(0,+)/Double(available.count))
        VStack(alignment:.leading,spacing:25) {
            PageHeader(title:"Patterns emerge.",eyebrow:"Your trends",model:model)
            HStack(spacing:4) {
                ForEach([7,28],id:\.self) { days in
                    Button { withAnimation(.easeOut(duration:0.2)) { model.trendDays = days; inspectedDate = nil } } label: {
                        Text(days == 7 ? "Past week" : "Past month").font(FormType.medium(12))
                            .foregroundStyle(model.trendDays == days ? FormPalette.ink : FormPalette.secondary)
                            .frame(maxWidth:.infinity).padding(.vertical,12)
                            .background(model.trendDays == days ? .white.opacity(0.085) : .clear,in:Capsule())
                    }.buttonStyle(PressStyle())
                }
            }.padding(4).background(.white.opacity(0.025),in:Capsule())
            if staticRendering {
                GeometryReader { _ in metricSelector.fixedSize() }.frame(height:40).clipped()
            } else {
                ScrollView(.horizontal) { metricSelector }.scrollIndicators(.hidden)
            }
            if model.mode == .demo { Text("SAMPLE DATA").eyebrow(FormPalette.sleep) }
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:7) {
                        Text(inspectedDate.map { FormModel.dateLabel($0,format:"MMM d").uppercased() } ?? (model.trendMetric == .strain ? "COMPLETE-DAY AVERAGE" : "AVAILABLE-DAY AVERAGE"))
                            .eyebrow()
                        HStack(alignment:.firstTextBaseline,spacing:7) {
                            Text(numberText(displayedValue,digits:model.trendMetric.digits))
                                .font(FormType.display(67)).tracking(-2.5).monospacedDigit()
                            Text(model.trendMetric.unit).font(FormType.text(14)).foregroundStyle(model.trendMetric.tint)
                        }.lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer()
                    Image(systemName:model.trendMetric.symbol).font(.system(size:24,weight:.light)).foregroundStyle(model.trendMetric.tint).padding(.top,10)
                }
                HistoryChart(points:points,tint:model.trendMetric.tint,
                             maxValue:[.sleep,.recovery].contains(model.trendMetric) ? 100 : nil,
                             selectedDate:inspectedDate,height:180) { inspectedDate = $0 }
                HStack {
                    Text(model.trendMetric == .strain ? "\(available.count) complete days averaged" : "\(available.count) / \(model.trendDays) days with readings").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                    Spacer()
                    if inspectedDate != nil { Button("Reset") { inspectedDate = nil }.font(FormType.medium(11)).foregroundStyle(model.trendMetric.tint) }
                }
            }.padding(21).formPanel(tint:model.trendMetric.tint)
            HStack(alignment:.top,spacing:12) {
                Image(systemName:"circle.dotted").font(.system(size:16)).foregroundStyle(model.trendMetric.tint)
                Text(model.trendMetric == .strain ? "Minutes with elevated heart rate. The average uses finished days with at least 90% recording coverage; partial days stay on the chart without entering that average." : available.isEmpty ? "No usable readings in this period. Recorded values will appear as they become available." : "Every point is an observed day. Missing or calibrating days stay open, so the pattern stays honest.")
                    .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(3)
            }.padding(.horizontal,3)
            SectionHeading(title:"Day by day",detail:model.mode == .demo ? "SAMPLE DATA" : "RECORDED")
            LazyVStack(spacing:0) {
                ForEach(Array(points.reversed())) { point in
                    Button {
                        model.selectedDate = point.date; model.selectedMetric = model.trendMetric
                    } label: {
                        HStack(spacing:12) {
                            VStack(alignment:.leading,spacing:3) {
                                Text(FormModel.dateLabel(point.date,format:"EEEE")).font(FormType.medium(13)).foregroundStyle(FormPalette.ink)
                                Text(FormModel.dateLabel(point.date,format:"MMM d")).font(FormType.text(10)).foregroundStyle(FormPalette.muted)
                            }
                            Spacer()
                            Text(numberText(point.value,digits:model.trendMetric.digits)).font(FormType.medium(22)).monospacedDigit().foregroundStyle(point.value == nil ? FormPalette.muted : model.trendMetric.tint)
                            Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(FormPalette.muted)
                        }.padding(.vertical,15).contentShape(Rectangle())
                    }.buttonStyle(PressStyle())
                    if point.date != points.first?.date { Hairline() }
                }
            }.padding(.horizontal,20).formPanel(tint:model.trendMetric.tint)
        }
    }
    private var metricSelector: some View {
                HStack(spacing:9) {
                    ForEach(FormMetric.allCases) { metric in
                        Button { model.trendMetric = metric; inspectedDate = nil } label: {
                            Text(metric.shortTitle).font(FormType.medium(12)).padding(.horizontal,15).padding(.vertical,10)
                                .foregroundStyle(model.trendMetric == metric ? FormPalette.background : FormPalette.secondary)
                                .background(model.trendMetric == metric ? metric.tint : FormPalette.surface,in:Capsule())
                        }.buttonStyle(PressStyle())
                    }
                }
    }

}
