import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

public struct FormRootView: View {
    @Bindable private var model: FormModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.formStaticRendering) private var staticRendering
    @ViewState private var importing = false
    public init(model: FormModel) { self.model = model }
    public var body: some View {
        ZStack {
            FormAtmosphere(tint: model.tab == .age ? FormPalette.age : FormPalette.recovery)
            if model.showsWelcome { WelcomeView(model: model, importing: $importing) }
            else if model.input == nil { SessionRestoreView(model: model) }
            else {
                if staticRendering {
                    GeometryReader { geometry in
                        screenContent.frame(width:geometry.size.width).fixedSize(horizontal:false,vertical:true)
                    }.clipped()
                } else {
                    ScrollView { screenContent }
                        .scrollIndicators(.hidden)
                        .refreshable { await model.refresh() }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.input != nil { tabBar }
        }
        .foregroundStyle(FormPalette.ink).tint(FormPalette.recovery).preferredColorScheme(.dark)
        .sheet(item: $model.selectedMetric) { metric in
            MetricDetailView(model: model, metric: metric)
                .presentationBackground(FormPalette.background)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.showConnection) {
            ConnectionView(model: model, importing: $importing)
                .presentationBackground(FormPalette.background)
                .presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { model.importCanonical(try Data(contentsOf: url)) }
                catch { model.notice = "The selected file could not be opened." }
            case .failure: model.notice = "Import was cancelled or the file could not be opened."
            }
        }
        .alert("BetterFit", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onOpenURL { model.open($0) }
        .task {
            await model.startup()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                if scenePhase == .active { await model.refresh(force: false) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh(force: false) } }
        }
    }
    private var screenContent: some View {
        VStack(spacing:26) {
            switch model.tab {
            case .today: TodayView(model:model)
            case .trends: TrendsView(model:model)
            case .age: AgeView(model:model)
            }
        }.padding(.horizontal,24).padding(.top,22).padding(.bottom,24)
            .frame(maxWidth:560).frame(maxWidth:.infinity)
    }
    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(FormTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response:0.32,dampingFraction:0.85)) { model.tab = tab }
                    #if os(iOS)
                    UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab == .today ? "circle.grid.2x2" : tab == .trends ? "chart.xyaxis.line" : "circle.hexagongrid")
                            .font(.system(size:14,weight: model.tab == tab ? .semibold : .regular))
                        Text(tab.rawValue).font(FormType.medium(12))
                    }.foregroundStyle(model.tab == tab ? FormPalette.ink : FormPalette.secondary)
                        .frame(maxWidth:.infinity).frame(height:44)
                        .background(model.tab == tab ? .white.opacity(0.09) : .clear, in: Capsule())
                }.buttonStyle(PressStyle())
                    .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    .accessibilityIdentifier("tab_\(tab.rawValue.lowercased())")
            }
        }
        .padding(6).background(FormPalette.surface.opacity(0.97), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.09),lineWidth:0.7))
        .shadow(color:.black.opacity(0.28),radius:20,y:8)
        .padding(.horizontal,34).padding(.top,10).padding(.bottom,14)
        .background(LinearGradient(colors:[FormPalette.background.opacity(0),FormPalette.background.opacity(0.98)],startPoint:.top,endPoint:.bottom))
    }
}

struct PageHeader: View {
    var title: String
    var eyebrow: String
    var model: FormModel
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment:.leading,spacing:5) {
                Text(eyebrow.uppercased()).eyebrow()
                Text(title).font(FormType.title(32)).tracking(-1.2)
            }
            Spacer(minLength:12)
            Button { model.showConnection = true } label: {
                ZStack(alignment:.bottomTrailing) {
                    Circle().fill(.white.opacity(0.035)).overlay(Circle().strokeBorder(.white.opacity(0.12),lineWidth:0.7))
                    Image(systemName:"slider.horizontal.3").font(.system(size:17,weight:.medium)).foregroundStyle(FormPalette.ink).frame(width:44,height:44)
                    Circle().fill(model.mode == .connected ? FormPalette.recovery : model.mode == .demo ? FormPalette.sleep : FormPalette.age)
                        .frame(width:7,height:7).overlay(Circle().stroke(FormPalette.background,lineWidth:2)).offset(x:-1,y:-1)
                }.frame(width:44,height:44)
            }.buttonStyle(PressStyle()).accessibilityLabel("Connection and preferences")
        }
    }
}

struct AgeTeaser: View {
    var model: FormModel
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                Text("THE LONG VIEW").eyebrow(FormPalette.age)
                Text("Biological Age").font(FormType.title(20)).tracking(-0.5)
                if let age = model.scores?.biologicalAge.score.value {
                    HStack(alignment:.firstTextBaseline,spacing:5) {
                        Text(numberText(age,digits:1)).font(FormType.display(36)).tracking(-1)
                        Text("years").font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
                    }
                } else {
                    Text("\(model.scores?.biologicalAge.collection.eligibleDays ?? 0) of 7 days collected")
                        .font(FormType.medium(12)).foregroundStyle(FormPalette.age)
                }
                Text("Movement estimate").font(FormType.text(10)).foregroundStyle(FormPalette.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            OrbitalIllustration().frame(width:95,height:100).clipped()
            Image(systemName:"chevron.right").font(.system(size:10)).foregroundStyle(FormPalette.secondary).padding(.leading,3)
        }.padding(20).formPanel(tint:FormPalette.age)
    }
}

struct InlineNotice: View {
    var text: String
    var tint: Color
    var body: some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:"info.circle").foregroundStyle(tint)
            Text(text).font(FormType.text(12)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading).formPanel(tint:tint,radius:15)
    }
}
