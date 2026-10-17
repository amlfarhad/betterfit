import SwiftUI

// Explicit wrapper alias avoids requiring Xcode-only SwiftUI State macros in CLT previews.
typealias ViewState<Value> = SwiftUI.State<Value>
private struct StaticRenderingKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var formStaticRendering: Bool {
        get { self[StaticRenderingKey.self] }
        set { self[StaticRenderingKey.self] = newValue }
    }
}

public enum FormPalette {
    public static let background = Color(hex: 0x0D1113)
    public static let surface = Color(hex: 0x181E21)
    public static let lifted = Color(hex: 0x20272A)
    public static let ink = Color(hex: 0xF2F1EA)
    public static let secondary = Color(hex: 0xA0A9AD)
    public static let muted = Color(hex: 0x657277)
    public static let recovery = Color(hex: 0xD6F58B)
    public static let strain = Color(hex: 0x8DCBEC)
    public static let sleep = Color(hex: 0xB7A5EE)
    public static let age = Color(hex: 0xE4D5B9)
    public static let warning = Color(hex: 0xE8BD84)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255)/255,
                  green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, opacity: 1)
    }
}

enum FormType {
    static func display(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Light", size: size, relativeTo: .largeTitle) }
    static func title(_ size: CGFloat = 30) -> Font { .custom("AvenirNext-DemiBold", size: size, relativeTo: .title) }
    static func text(_ size: CGFloat = 14) -> Font { .custom("AvenirNext-Regular", size: size, relativeTo: .body) }
    static func medium(_ size: CGFloat = 14) -> Font { .custom("AvenirNext-Medium", size: size, relativeTo: .body) }
    static func label(_ size: CGFloat = 10) -> Font { .custom("AvenirNext-DemiBold", size: size, relativeTo: .caption) }
}

struct FormAtmosphere: View {
    var tint: Color = FormPalette.recovery
    var body: some View {
        ZStack {
            FormPalette.background
            RadialGradient(colors: [tint.opacity(0.07), .clear], center: .topLeading,
                           startRadius: 10, endRadius: 430)
            LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
        }.ignoresSafeArea()
    }
}

struct Panel: ViewModifier {
    var tint: Color = .white
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [FormPalette.lifted.opacity(0.8), FormPalette.surface],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(RadialGradient(colors: [tint.opacity(0.07), .clear], center: .topTrailing,
                                                 startRadius: 0, endRadius: 240))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.025)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                    }
            }
    }
}

extension View {
    func formPanel(tint: Color = .white, radius: CGFloat = 24) -> some View { modifier(Panel(tint: tint, radius: radius)) }
    func eyebrow(_ color: Color = FormPalette.secondary) -> some View {
        font(FormType.label()).tracking(1.7).foregroundStyle(color)
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct GlyphButton: View {
    let symbol: String
    let label: String
    var color: Color = FormPalette.ink
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(color).frame(width: 44, height: 44)
                .background(.white.opacity(0.045), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 0.6))
        }.buttonStyle(PressStyle()).accessibilityLabel(label)
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(FormType.title(19)).foregroundStyle(FormPalette.ink)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(FormType.medium(11)).foregroundStyle(FormPalette.secondary) }
        }
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) }
}

struct FormWordmark: View {
    var small = false
    var body: some View {
        HStack(spacing: small ? 7 : 10) {
            FormMark().stroke(FormPalette.ink, style: StrokeStyle(lineWidth: small ? 1.8 : 2.4, lineCap: .round))
                .frame(width: small ? 18 : 25, height: small ? 18 : 25)
            Text("BetterFit").font(FormType.title(small ? 15 : 21)).tracking(-0.6)
        }.foregroundStyle(FormPalette.ink).accessibilityElement(children: .ignore).accessibilityLabel("BetterFit")
    }
}

struct FormMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            p.addArc(center: center, radius: rect.width * 0.44, startAngle: .degrees(45), endAngle: .degrees(320), clockwise: false)
            p.move(to: CGPoint(x: center.x + rect.width * 0.25, y: center.y))
            p.addArc(center: center, radius: rect.width * 0.25, startAngle: .degrees(0), endAngle: .degrees(265), clockwise: false)
        }
    }
}

struct StatusDot: View {
    var color: Color = FormPalette.recovery
    var body: some View { Circle().fill(color).frame(width: 5, height: 5).shadow(color: color.opacity(0.25), radius: 3) }
}
