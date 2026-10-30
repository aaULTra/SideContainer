// Native adaptation of macos-ui's window state transitions; see Notices/.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum TahoeWindowKind: String, Codable { case browser, applications, files, settings, guest }
enum TahoeWindowLayout: String, Codable { case floating, maximized, left, right }
enum TahoeResizeEdge: CaseIterable { case top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

struct TahoeWindow: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    let kind: TahoeWindowKind
    var frame: CGRect
    var layout: TahoeWindowLayout = .floating
    var minimized = false
    var resourceID: String?
}

/// Pure state: UI objects, guest processes and browser sessions live elsewhere.
/// Array order is back-to-front. Fullscreen never replaces the window's identity.
struct TahoeWindowState {
    private(set) var windows: [TahoeWindow] = []
    private(set) var activeID: UUID?
    private(set) var fullscreenID: UUID?
    private(set) var canvas = CGSize(width: 1024, height: 768)

    var workArea: CGRect {
        CGRect(x: 0, y: 32, width: canvas.width, height: max(1, canvas.height - 122))
    }

    mutating func setCanvas(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        canvas = size
        for index in windows.indices { windows[index].frame = constrain(windows[index].frame) }
    }

    @discardableResult mutating func open(_ kind: TahoeWindowKind, title: String, resourceID: String? = nil) -> UUID {
        let id = UUID()
        let offset = CGFloat(windows.count % 6) * 24
        let frame = constrain(CGRect(x: 64 + offset, y: 64 + offset, width: 740, height: 500))
        windows.append(TahoeWindow(id: id, title: title, kind: kind, frame: frame, resourceID: resourceID))
        focus(id)
        return id
    }

    mutating func focus(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        var window = windows.remove(at: index)
        window.minimized = false
        windows.append(window)
        activeID = id
        if fullscreenID != id { fullscreenID = nil }
    }

    mutating func close(_ id: UUID) {
        windows.removeAll { $0.id == id }
        if fullscreenID == id { fullscreenID = nil }
        if activeID == id { activeID = windows.last(where: { !$0.minimized })?.id }
    }

    mutating func minimize(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].minimized = true
        if fullscreenID == id { fullscreenID = nil }
        if activeID == id { activeID = windows.last(where: { !$0.minimized })?.id }
    }

    mutating func setLayout(_ layout: TahoeWindowLayout, for id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[index].layout = layout
        focus(id)
    }

    mutating func toggleMaximize(_ id: UUID) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        setLayout(window.layout == .maximized ? .floating : .maximized, for: id)
    }

    mutating func toggleFullscreen(_ id: UUID) {
        guard windows.contains(where: { $0.id == id }) else { return }
        let wasFullscreen = fullscreenID == id
        focus(id)
        fullscreenID = wasFullscreen ? nil : id
    }

    func displayFrame(_ window: TahoeWindow) -> CGRect {
        if fullscreenID == window.id { return CGRect(origin: .zero, size: canvas) }
        switch window.layout {
        case .floating: return window.frame
        case .maximized: return workArea
        case .left: return CGRect(x: workArea.minX, y: workArea.minY, width: workArea.width / 2, height: workArea.height)
        case .right: return CGRect(x: workArea.midX, y: workArea.minY, width: workArea.width / 2, height: workArea.height)
        }
    }

    mutating func move(_ id: UUID, from initial: CGRect, translation: CGSize) {
        guard let index = windows.firstIndex(where: { $0.id == id }), fullscreenID == nil else { return }
        windows[index].layout = .floating
        windows[index].frame = constrain(initial.offsetBy(dx: translation.width, dy: translation.height))
    }

    mutating func resize(_ id: UUID, from initial: CGRect, edge: TahoeResizeEdge, translation: CGSize) {
        guard let index = windows.firstIndex(where: { $0.id == id }), fullscreenID == nil else { return }
        let minimum = CGSize(width: min(360, workArea.width), height: min(240, workArea.height))
        var left = initial.minX, right = initial.maxX, top = initial.minY, bottom = initial.maxY
        switch edge {
        case .left, .topLeft, .bottomLeft: left = min(max(workArea.minX, left + translation.width), right - minimum.width)
        case .right, .topRight, .bottomRight: right = max(min(workArea.maxX, right + translation.width), left + minimum.width)
        default: break
        }
        switch edge {
        case .top, .topLeft, .topRight: top = min(max(workArea.minY, top + translation.height), bottom - minimum.height)
        case .bottom, .bottomLeft, .bottomRight: bottom = max(min(workArea.maxY, bottom + translation.height), top + minimum.height)
        default: break
        }
        windows[index].layout = .floating
        windows[index].frame = constrain(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    private func constrain(_ frame: CGRect) -> CGRect {
        let width = min(max(360, frame.width), workArea.width)
        let height = min(max(240, frame.height), workArea.height)
        return CGRect(x: min(max(workArea.minX, frame.minX), workArea.maxX - width),
                      y: min(max(workArea.minY, frame.minY), workArea.maxY - height), width: width, height: height)
    }
}
