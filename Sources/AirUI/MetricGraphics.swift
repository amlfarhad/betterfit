import SwiftUI

struct ScoreGauge: View {
    var value: Double?
    var maximum: Double = 100
    var progress: Double? = nil
    var tint: Color
    var size: CGFloat = 160
    var caption: String = ""
    var compact = false
    var showsValue = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.formStaticRendering) private var staticRendering
    @ViewState private var appeared = false
    private var fraction: Double { min(1, max(0, progress ?? ((value ?? 0)/maximum))) }
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.095), .clear], center: .center,
                                         startRadius: 0, endRadius: size * 0.55)).padding(-12)
            Circle().trim(from: 0, to: 0.78)
                .stroke(tint.opacity(0.10), style: StrokeStyle(lineWidth: compact ? 4 : 7, lineCap: .round))
                .rotationEffect(.degrees(129.6))
            Circle().trim(from: 0, to: 0.78 * (appeared || reduceMotion || staticRendering ? fraction : 0))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint, tint], center: .center,
                                        startAngle: .degrees(120), endAngle: .degrees(410)),
                        style: StrokeStyle(lineWidth: compact ? 4 : 7, lineCap: .round))
                .rotationEffect(.degrees(129.6))
            if !compact {
                Circle().trim(from: 0, to: 0.78)
                    .stroke(.white.opacity(0.13), style: StrokeStyle(lineWidth: 2, dash: [1, 7]))
                    .rotationEffect(.degrees(129.6)).padding(12)
            }
            if showsValue { VStack(spacing: compact ? 1 : 0) {
                Text(numberText(value, digits: maximum == 21 ? 1 : 0))
                    .font(FormType.display(compact ? size * 0.32 : size * 0.39))
                    .tracking(-2).monospacedDigit().foregroundStyle(FormPalette.ink)
                    .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
                if !caption.isEmpty {
                    Text(caption).font(FormType.label(compact ? 8 : 9)).tracking(1.5)
                        .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
                }
            }.padding(.bottom, size * 0.015).padding(.horizontal, 10) }
            VStack { Spacer(); Circle().fill(tint.opacity(value == nil ? 0.4 : 0.9)).frame(width: 4, height: 4).padding(.bottom, 4) }
        }.frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { "\(numberText($0, digits: maximum == 21 ? 1 : 0)) out of \(Int(maximum))" } ?? caption)
            .onAppear {
                if reduceMotion { appeared = true }
                else { withAnimation(.easeOut(duration: 0.8)) { appeared = true } }
            }
    }
}

struct HistoryChart: View {
    var points: [ChartPoint]
    var tint: Color
    var maxValue: Double? = nil
    var selectedDate: String? = nil
    var height: CGFloat = 136
    var showLabels = true
    var onSelect: ((String) -> Void)? = nil
    private var upper: Double { max(1, maxValue ?? ((points.compactMap(\.value).max() ?? 1) * 1.15)) }
    var body: some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 8)
                let plotHeight = max(1, geometry.size.height - 12)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for f in [0.0, 0.5, 1.0] {
                            var grid = Path(); let y = 6 + plotHeight * f
                            grid.move(to: CGPoint(x: 4, y: y)); grid.addLine(to: CGPoint(x: size.width-4, y: y))
                            context.stroke(grid, with: .color(.white.opacity(0.065)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
                        }
                        var segments: [[CGPoint]] = []; var current: [CGPoint] = []
                        for (i, point) in points.enumerated() {
                            guard let value = point.value else {
                                if !current.isEmpty { segments.append(current); current = [] }; continue
                            }
                            let x = 4 + width * CGFloat(i) / CGFloat(max(1, points.count-1))
                            let y = 6 + plotHeight * (1-CGFloat(min(upper, max(0,value))/upper))
                            current.append(CGPoint(x: x, y: y))
                        }
                        if !current.isEmpty { segments.append(current) }
                        for segment in segments {
                            guard let first = segment.first, let last = segment.last else { continue }
                            var line = Path(); line.move(to: first)
                            for point in segment.dropFirst() { line.addLine(to: point) }
                            var fill = line; fill.addLine(to: CGPoint(x: last.x, y: 6+plotHeight))
                            fill.addLine(to: CGPoint(x: first.x, y: 6+plotHeight)); fill.closeSubpath()
                            context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.17), tint.opacity(0.005)]),
                                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            if points.count <= 8 || segment.count == 1 {
                                for point in segment {
                                    context.fill(Path(ellipseIn: CGRect(x: point.x-2.5,y: point.y-2.5,width: 5,height: 5)), with: .color(tint))
                                }
                            }
                        }
                        if let selectedDate, let i = points.firstIndex(where: { $0.date == selectedDate }),
                           let value = points[i].value {
                            let x = 4+width*CGFloat(i)/CGFloat(max(1,points.count-1))
                            let y = 6+plotHeight*(1-CGFloat(min(upper,max(0,value))/upper))
                            var guide = Path(); guide.move(to: CGPoint(x:x,y:0));guide.addLine(to:CGPoint(x:x,y:size.height))
                            context.stroke(guide, with: .color(tint.opacity(0.35)), style: StrokeStyle(lineWidth:0.7,dash:[3,3]))
                            context.fill(Path(ellipseIn:CGRect(x:x-4,y:y-4,width:8,height:8)),with:.color(FormPalette.ink))
                        }
                    }
                    if points.compactMap(\.value).isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "chart.xyaxis.line").font(.system(size: 20, weight: .light)).foregroundStyle(tint.opacity(0.6))
                            Text("Your history starts here").font(FormType.medium(12)).foregroundStyle(FormPalette.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { gesture in
                    guard !points.isEmpty,
                          abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                    let fraction = max(0,min(1,(gesture.location.x-4)/width))
                    let index = Int((fraction*CGFloat(points.count-1)).rounded())
                    if points[index].date != selectedDate { onSelect?(points[index].date) }
                }, including: onSelect == nil ? .none : .all)
                .simultaneousGesture(SpatialTapGesture().onEnded { gesture in
                    guard !points.isEmpty else { return }
                    let fraction = max(0,min(1,(gesture.location.x-4)/width))
                    let index = Int((fraction*CGFloat(points.count-1)).rounded())
                    if points[index].date != selectedDate { onSelect?(points[index].date) }
                }, including: onSelect == nil ? .none : .all)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("History chart, \(points.compactMap(\.value).count) available readings")
            }.frame(height: height)
            if showLabels, let first = points.first, let last = points.last {
                HStack {
                    Text(FormModel.dateLabel(first.date, format: "MMM d"))
                    Spacer()
                    Text(FormModel.dateLabel(last.date, format: "MMM d"))
                }.font(FormType.medium(10)).foregroundStyle(FormPalette.muted)
            }
        }
    }
}

struct CollectionStrip: View {
    let days: [(String, Bool)]
    var tint: Color = FormPalette.age
    var body: some View {
        HStack(spacing: 7) {
            ForEach(days.indices, id: \.self) { i in
                VStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(days[i].1 ? tint : .white.opacity(0.06))
                        .overlay {
                            if days[i].1 { Image(systemName: "checkmark").font(.system(size: 10,weight:.bold)).foregroundStyle(FormPalette.background) }
                            else { Circle().fill(.white.opacity(0.13)).frame(width:3,height:3) }
                        }.frame(height: 29)
                    Text(FormModel.dateLabel(days[i].0, format: "EEEEE")).font(FormType.label(9)).foregroundStyle(FormPalette.secondary)
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(days[i].0), \(days[i].1 ? "qualifying day" : "not yet eligible")")
            }
        }
    }
}

struct OrbitalIllustration: View {
    var tint: Color = FormPalette.age
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.16),.clear], center:.center,startRadius:5,endRadius:85))
            ForEach(0..<5) { i in
                Ellipse().stroke(tint.opacity(0.12+Double(i)*0.025),lineWidth:0.7)
                    .frame(width:CGFloat(78+i*12),height:CGFloat(34+i*9))
                    .rotationEffect(.degrees(-35+Double(i)*7))
            }
            Circle().fill(LinearGradient(colors:[tint.opacity(0.8),tint.opacity(0.22),FormPalette.surface],startPoint:.topLeading,endPoint:.bottomTrailing))
                .frame(width:43,height:43)
                .overlay(Circle().strokeBorder(tint.opacity(0.25),lineWidth:0.5))
                .shadow(color:.black.opacity(0.35),radius:12,x:7,y:9)
        }.frame(width:130,height:130).accessibilityHidden(true)
    }
}
