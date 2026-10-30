import SwiftUI

struct TahoeDesktopView: View {
    @ObservedObject private var workspace = TahoeWorkspace.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var performanceTarget: UUID?
    @FocusState private var spotlightFocused: Bool
    @AppStorage("TahoeDarkAppearance") private var darkAppearance = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if workspace.state.fullscreenID == nil {
                    LinearGradient(colors: [.indigo, .blue, .cyan.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(alignment: .topTrailing) {
                            Button { workspace.open(.files) } label: {
                                VStack { Image(systemName: "folder.fill").font(.system(size: 44)); Text("Documents").font(.caption) }
                                    .foregroundStyle(.white).padding(32)
                            }.buttonStyle(.plain).padding(.top, 36)
                        }
                } else { Color.black }

                // These children retain identity, hierarchy and content in every presentation state.
                ForEach(workspace.state.windows) { window in
                    TahoeDesktopWindow(window: window, workspace: workspace) {
                        windowContent(window)
                    }
                    .zIndex(Double(workspace.state.windows.firstIndex(where: { $0.id == window.id }) ?? 0))
                }

                if workspace.state.fullscreenID == nil {
                    VStack {
                        TahoeMenuBar(workspace: workspace, performanceTarget: $performanceTarget)
                        Spacer()
                        TahoeDock(workspace: workspace).padding(.bottom, 12)
                    }
                    .zIndex(1000)
                } else if let id = workspace.state.fullscreenID {
                    Button { workspace.state.toggleFullscreen(id) } label: {
                        Label("Exit Fullscreen", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12)).padding(8).background(.regularMaterial, in: Capsule())
                    }.buttonStyle(.plain).padding(8).zIndex(1000)
                }
                if workspace.showSpotlight { spotlight.zIndex(2000) }
                if workspace.showOverview { overview.zIndex(2000) }
            }
            .clipped().coordinateSpace(name: "tahoe-desktop")
            .onAppear { workspace.state.setCanvas(geometry.size); workspace.start() }
            .onChange(of: geometry.size) { _, size in workspace.state.setCanvas(size) }
        }
        .preferredColorScheme(darkAppearance ? .dark : .light)
        .tint(TahoeDesign.accent)
        .background {
            // Keyboard shortcuts stay outside browser/guest content so text entry keeps native handling.
            Group {
                Button("New Browser Window") { workspace.openBrowser() }.keyboardShortcut("n", modifiers: .command)
                Button("Spotlight") { workspace.showSpotlight.toggle() }.keyboardShortcut(" ", modifiers: .command)
                Button("Minimise Window") { if let id = workspace.state.activeID { workspace.state.minimize(id) } }.keyboardShortcut("m", modifiers: .command)
                Button("Exit Fullscreen") { if let id = workspace.state.fullscreenID { workspace.state.toggleFullscreen(id) } }.keyboardShortcut(.escape, modifiers: [])
            }.hidden()
        }
        .confirmationDialog("Unload other browser pages? Unsaved page state and navigation history will be lost.",
                            isPresented: Binding(get: { performanceTarget != nil }, set: { if !$0 { performanceTarget = nil } }), titleVisibility: .visible) {
            Button("Enter Performance Fullscreen", role: .destructive) {
                if let id = performanceTarget { workspace.performanceFullscreen(id) }
                performanceTarget = nil
            }
        }
    }

    @ViewBuilder private func windowContent(_ window: TahoeWindow) -> some View {
        switch window.kind {
        case .browser:
            if let session = workspace.browsers[window.id] { TahoeBrowserView(session: session) }
        case .guest:
            if let session = workspace.guests[window.id] { TahoeGuestView(session: session) }
        case .applications: TahoeApplicationsView(workspace: workspace)
        case .files: TahoeFilesView()
        case .settings: TahoeSettingsView()
        }
    }

    private var spotlight: some View {
        ZStack {
            Color.black.opacity(0.25).onTapGesture { workspace.showSpotlight = false }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search applications or enter a website", text: $workspace.search)
                    .focused($spotlightFocused)
                    .font(.title3).onSubmit {
                        if let url = TahoeAddress.url(for: workspace.search) { workspace.openBrowser(url: url) }
                        workspace.showSpotlight = false
                    }.padding(12)
                TahoeApplicationsView(workspace: workspace, filter: workspace.search)
            }
            .frame(maxWidth: 600, maxHeight: 420).modifier(TahoeGlass()).padding()
            .onAppear { spotlightFocused = true }
        }
    }

    private var overview: some View {
        ZStack {
            Color.black.opacity(0.65).onTapGesture { workspace.showOverview = false }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))], spacing: 20) {
                    ForEach(workspace.state.windows) { window in
                        Button {
                            workspace.state.focus(window.id)
                            workspace.showOverview = false
                        } label: {
                            VStack(spacing: 16) {
                                Image(systemName: window.kind == .browser ? "globe" : "macwindow").font(.largeTitle)
                                Text(window.title)
                                if window.minimized { Text("Minimised").font(.caption) }
                            }.frame(maxWidth: .infinity, minHeight: 140).modifier(TahoeGlass())
                        }.buttonStyle(.plain)
                    }
                }.padding(40)
            }
            .overlay(alignment: .topTrailing) { Button("Done") { workspace.showOverview = false }.padding() }
        }
    }
}

private struct TahoeDesktopWindow<Content: View>: View {
    let window: TahoeWindow
    @ObservedObject var workspace: TahoeWorkspace
    @ViewBuilder let content: () -> Content
    @State private var gestureStart: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fullscreen: Bool { workspace.state.fullscreenID == window.id }
    private var visible: Bool { !window.minimized && (workspace.state.fullscreenID == nil || fullscreen) }

    var body: some View {
        let frame = workspace.state.displayFrame(window)
        VStack(spacing: 0) {
            titleBar.frame(height: fullscreen ? 0 : TahoeDesign.titleHeight).clipped().allowsHitTesting(!fullscreen)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        }
        .frame(width: frame.width, height: frame.height)
        .modifier(TahoeGlass(radius: fullscreen ? 0 : TahoeDesign.windowRadius))
        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : TahoeDesign.windowRadius))
        .overlay { if !fullscreen { resizeHandles } }
        .overlay {
            RoundedRectangle(cornerRadius: fullscreen ? 0 : TahoeDesign.windowRadius)
                .strokeBorder(Color.white.opacity(workspace.state.activeID == window.id ? 0.4 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(visible && !fullscreen ? 0.25 : 0), radius: 18, y: 8)
        .position(x: frame.midX, y: frame.midY)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible).accessibilityHidden(!visible)
        .simultaneousGesture(TapGesture().onEnded { workspace.state.focus(window.id) })
        // Animate state transitions only. Live drag/resize is immediate.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: window.layout)
    }

    private var titleBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                trafficLight(.red, symbol: "xmark", label: "Close \(window.title)") { workspace.close(window.id) }
                trafficLight(.yellow, symbol: "minus", label: "Minimise \(window.title)") { workspace.state.minimize(window.id) }
                trafficLight(.green, symbol: "plus", label: "Maximise \(window.title)") { workspace.state.toggleMaximize(window.id) }
            }.padding(.horizontal, 14)
            Text(window.title).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { workspace.state.toggleMaximize(window.id) }
                .gesture(DragGesture(coordinateSpace: .named("tahoe-desktop"))
                    .onChanged { value in
                        if gestureStart == nil {
                            gestureStart = workspace.state.displayFrame(window)
                            workspace.state.focus(window.id)
                        }
                        if let gestureStart { workspace.state.move(window.id, from: gestureStart, translation: value.translation) }
                    }
                    .onEnded { value in
                        gestureStart = nil
                        let area = workspace.state.workArea
                        if value.location.x < area.minX + 16 { workspace.state.setLayout(.left, for: window.id) }
                        else if value.location.x > area.maxX - 16 { workspace.state.setLayout(.right, for: window.id) }
                        else if value.location.y < area.minY + 12 { workspace.state.setLayout(.maximized, for: window.id) }
                    })
            Button { workspace.state.toggleFullscreen(window.id) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).frame(width: 36, height: 32)
            }.buttonStyle(.plain).accessibilityLabel("Fullscreen \(window.title)")
        }
    }

    private func trafficLight(_ color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 12, height: 12)
                .overlay { Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.6)) }
                .frame(width: 22, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private var resizeHandles: some View {
        GeometryReader { geometry in
            ForEach(Array(TahoeResizeEdge.allCases.enumerated()), id: \.offset) { _, edge in
                let box = handleFrame(edge, size: geometry.size)
                Color.clear.frame(width: box.width, height: box.height).contentShape(Rectangle())
                    .position(x: box.midX, y: box.midY)
                    .gesture(DragGesture(coordinateSpace: .named("tahoe-desktop"))
                        .onChanged { value in
                            if gestureStart == nil { gestureStart = workspace.state.displayFrame(window); workspace.state.focus(window.id) }
                            if let gestureStart { workspace.state.resize(window.id, from: gestureStart, edge: edge, translation: value.translation) }
                        }.onEnded { _ in gestureStart = nil })
                    .accessibilityLabel("Resize \(window.title)")
            }
        }
    }

    private func handleFrame(_ edge: TahoeResizeEdge, size: CGSize) -> CGRect {
        let grip: CGFloat = 10
        switch edge {
        case .top: return CGRect(x: grip, y: 0, width: max(0, size.width - 2 * grip), height: 5)
        case .bottom: return CGRect(x: grip, y: size.height - 5, width: max(0, size.width - 2 * grip), height: 5)
        case .left: return CGRect(x: 0, y: grip, width: 5, height: max(0, size.height - 2 * grip))
        case .right: return CGRect(x: size.width - 5, y: grip, width: 5, height: max(0, size.height - 2 * grip))
        case .topLeft: return CGRect(x: 0, y: 0, width: grip, height: grip)
        case .topRight: return CGRect(x: size.width - grip, y: 0, width: grip, height: grip)
        case .bottomLeft: return CGRect(x: 0, y: size.height - grip, width: grip, height: grip)
        case .bottomRight: return CGRect(x: size.width - grip, y: size.height - grip, width: grip, height: grip)
        }
    }
}

private struct TahoeMenuBar: View {
    @ObservedObject var workspace: TahoeWorkspace
    @Binding var performanceTarget: UUID?
    var body: some View {
        HStack(spacing: 18) {
            Menu {
                Button("Desktop Settings") { workspace.open(.settings) }
                Button("LiveContainer & SideInstaller") { workspace.showManagement = true }
            } label: { Image(systemName: "apple.logo") }
            Text(workspace.state.windows.first(where: { $0.id == workspace.state.activeID })?.title ?? "Finder").fontWeight(.semibold).lineLimit(1)
            Menu("File") {
                Button("New Browser Window") { workspace.openBrowser() }
                Button("Applications") { workspace.open(.applications) }
                Button("Documents") { workspace.open(.files) }
                if let id = workspace.state.activeID { Button("Close Window") { workspace.close(id) } }
            }
            Menu("Window") {
                if let id = workspace.state.activeID {
                    Button("Minimise") { workspace.state.minimize(id) }
                    Button("Maximise / Restore") { workspace.state.toggleMaximize(id) }
                    Button("Tile Left") { workspace.state.setLayout(.left, for: id) }
                    Button("Tile Right") { workspace.state.setLayout(.right, for: id) }
                    Button("Fullscreen") { workspace.state.toggleFullscreen(id) }
                    Button("Performance Fullscreen…") { performanceTarget = id }
                }
                Divider()
                ForEach(workspace.state.windows) { window in Button(window.title) { workspace.state.focus(window.id) } }
            }
            Spacer(minLength: 0)
            Button { workspace.showOverview = true } label: { Image(systemName: "rectangle.3.group") }.accessibilityLabel("Window overview")
            Button { workspace.showSpotlight = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Spotlight")
            Text(Date(), style: .time).monospacedDigit()
        }
        .font(.system(size: 13)).buttonStyle(.plain).padding(.horizontal, 16)
        .frame(height: 32).background(.regularMaterial)
    }
}

private struct TahoeDock: View {
    @ObservedObject var workspace: TahoeWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGFloat?
    private let items: [(TahoeWindowKind, String, String, Color)] = [
        (.files, "Finder", "folder.fill", .blue), (.browser, "Browser", "safari.fill", .cyan),
        (.applications, "Applications", "square.grid.2x2.fill", .indigo), (.settings, "Settings", "gearshape.fill", .gray)
    ]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        if let existing = workspace.state.windows.last(where: { $0.kind == item.0 }) { workspace.state.focus(existing.id) }
                        else { workspace.open(item.0) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.2).font(.system(size: 30)).foregroundStyle(.white)
                                .frame(width: 48, height: 48).background(item.3.gradient, in: RoundedRectangle(cornerRadius: 12))
                                .scaleEffect(scale(index), anchor: .bottom)
                            Circle().fill(workspace.state.windows.contains(where: { $0.kind == item.0 }) ? Color.primary : .clear).frame(width: 4, height: 4)
                        }.frame(width: 52, height: 66, alignment: .bottom)
                    }.buttonStyle(.plain).accessibilityLabel(item.1).help(item.1)
                        .contextMenu {
                            if item.0 == .browser { Button("New Browser Window") { workspace.openBrowser() } }
                        }
                }
                if !workspace.state.windows.isEmpty {
                    Divider().frame(height: 40)
                    ForEach(workspace.state.windows) { window in
                        Button { workspace.state.focus(window.id) } label: {
                            VStack {
                                Image(systemName: window.kind == .guest ? "app.fill" : "macwindow").font(.system(size: 24))
                                Text(window.title).font(.system(size: 9)).lineLimit(1)
                            }.frame(width: 54, height: 54).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel("Restore \(window.title)")
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .onContinuousHover { phase in
                    switch phase { case .active(let location): pointer = location.x; case .ended: pointer = nil }
                }
        }
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: min(workspace.state.canvas.width - 24, 850))
        .modifier(TahoeGlass(radius: 24))
    }
    private func scale(_ index: Int) -> CGFloat {
        guard let pointer, !reduceMotion else { return 1 }
        // macos-ui distance falloff, corrected for padding and fixed slot spacing.
        let center = 12 + CGFloat(index) * 60 + 26
        return max(1, 1.5 - abs(pointer - center) / 96)
    }
}
