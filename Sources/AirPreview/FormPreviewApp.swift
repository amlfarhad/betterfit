import SwiftUI
import AppKit
import AirUI
import FitbitMetrics

typealias PreviewState<Value> = SwiftUI.State<Value>

@main
struct FormPreviewApp: App {
    @PreviewState private var model: FormModel
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let model: FormModel
        if let index = arguments.firstIndex(of: "--input"), arguments.indices.contains(index+1),
           let data = try? Data(contentsOf: URL(fileURLWithPath:arguments[index+1])) {
            model = FormModel(preview:true)
            model.importCanonical(data)
        } else if arguments.contains("--welcome") {
            model = FormModel(preview:true)
        } else {
            model = FormModel(input:FormDemo.input(),mode:.demo,preview:true)
        }
        if let index = arguments.firstIndex(of:"--screen"),arguments.indices.contains(index+1) {
            switch arguments[index+1] {
            case "trends": model.tab = .trends
            case "age": model.tab = .age
            default: break
            }
        }
        _model = PreviewState(initialValue:model)
        if let index = arguments.firstIndex(of:"--render"),arguments.indices.contains(index+1) {
            let width:CGFloat
            if let w = arguments.firstIndex(of:"--width"),arguments.indices.contains(w+1),let v = Double(arguments[w+1]) { width = CGFloat(v) }
            else { width = 393 }
            let height: CGFloat
            if let h = arguments.firstIndex(of: "--height"), arguments.indices.contains(h+1), let v = Double(arguments[h+1]) { height = CGFloat(v) }
            else { height = 852 }
            let image = ImageRenderer(content: PreviewFrame(model:model).frame(width:width,height:height)
                .environment(\.colorScheme,.dark).environment(\.formStaticRendering,true))
            image.scale = 2
            image.proposedSize = ProposedViewSize(width:width,height:height)
            guard let data = image.nsImage?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data:data),let png = bitmap.representation(using:.png,properties:[:]) else {
                fputs("Could not render SwiftUI snapshot.\n",stderr); exit(1)
            }
            do { try png.write(to:URL(fileURLWithPath:arguments[index+1]),options:.atomic) }
            catch { fputs("Could not save snapshot.\n",stderr); exit(1) }
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("BetterFit · Native Preview") {
            PreviewFrame(model:model).frame(minWidth:375,idealWidth:393,maxWidth:560,minHeight:700,idealHeight:852)
        }.defaultSize(width:393,height:852).windowResizability(.contentSize)
    }
}

struct PreviewFrame: View {
    var model:FormModel
    var body: some View {
        VStack(spacing:0) {
            HStack {
                Text("9:41").font(.system(size:13,weight:.semibold))
                Spacer()
                HStack(spacing:5) {
                    Image(systemName:"cellularbars").font(.system(size:11))
                    Image(systemName:"wifi").font(.system(size:11,weight:.semibold))
                    Image(systemName:"battery.100percent").font(.system(size:17))
                }
            }.foregroundStyle(FormPalette.ink).padding(.horizontal,30).padding(.top,14).padding(.bottom,10)
                .accessibilityHidden(true)
            FormRootView(model:model).frame(maxWidth:.infinity,maxHeight:.infinity)
            Capsule().fill(FormPalette.ink.opacity(0.8)).frame(width:120,height:4).padding(.bottom,7)
                .accessibilityHidden(true)
        }.background(FormPalette.background).preferredColorScheme(.dark)
    }
}
