import SwiftUI

enum TahoeDesign {
    // MacVue regular-control tokens, expressed in points. See Notices/.
    static let controlHeight: CGFloat = 24
    static let controlRadius: CGFloat = 6
    static let windowRadius: CGFloat = 16
    static let accent = Color(red: 0, green: 136 / 255, blue: 1)
    static let titleHeight: CGFloat = 36
}

struct TahoeGlass: ViewModifier {
    var radius: CGFloat = TahoeDesign.windowRadius
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        // Only the background changes branches. Hosted content keeps its parent
        // and identity when accessibility transparency settings change.
        content.background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: radius).fill(Color(uiColor: .secondarySystemBackground))
            } else {
                if #available(iOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
                } else {
                    RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
                }
            }
        }
    }
}

struct TahoeControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13))
            .padding(.horizontal, 16).frame(minHeight: TahoeDesign.controlHeight)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06),
                        in: RoundedRectangle(cornerRadius: TahoeDesign.controlRadius))
    }
}

/// macos_ui's bounded, collapsible sidebar pattern; native layout and gestures.
struct TahoeSidebar<Sidebar: View, Content: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @State private var width: CGFloat = 190
    @State private var initialWidth: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 556 {
                    sidebar().frame(width: width).frame(maxHeight: .infinity, alignment: .top)
                        .background(.thinMaterial)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 6)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if initialWidth == nil { initialWidth = width }
                            width = min(320, max(160, (initialWidth ?? width) + value.translation.width))
                        }.onEnded { _ in initialWidth = nil })
                        .accessibilityLabel("Resize sidebar")
                }
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
