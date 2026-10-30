import Foundation

@main struct TahoeStateTests {
    static func main() {
        var state = TahoeWindowState()
        state.setCanvas(CGSize(width: 1194, height: 834))
        let browser = state.open(.browser, title: "Browser")
        let guest = state.open(.guest, title: "Guest", resourceID: "test-container")
        let original = state.windows.first(where: { $0.id == browser })!.frame

        state.minimize(guest)
        precondition(state.activeID == browser, "Minimising must focus the next visible window")
        state.focus(guest)
        precondition(!state.windows.last!.minimized && state.activeID == guest)
        state.toggleMaximize(browser)
        precondition(state.displayFrame(state.windows.last!) == state.workArea)
        state.toggleMaximize(browser)
        precondition(state.windows.last!.frame == original, "Maximise must not overwrite restore geometry")

        state.toggleFullscreen(guest)
        precondition(state.fullscreenID == guest)
        precondition(state.displayFrame(state.windows.last!).size == state.canvas)
        state.focus(browser)
        precondition(state.fullscreenID == nil, "Focusing another window must exit fullscreen")
        state.toggleFullscreen(browser)
        state.minimize(browser)
        precondition(state.fullscreenID == nil && state.activeID == guest)
        state.focus(browser)
        precondition(state.windows.last!.frame == original)

        for edge in TahoeResizeEdge.allCases {
            state.resize(browser, from: original, edge: edge, translation: CGSize(width: 10000, height: -10000))
            let frame = state.windows.first(where: { $0.id == browser })!.frame
            precondition(frame.width >= 360 && frame.height >= 240)
            precondition(state.workArea.contains(frame), "Every resize edge must keep the frame inside the usable desktop")
        }
        // Left/top resizing must preserve the opposite edge when minimum size is reached.
        state.resize(browser, from: original, edge: .topLeft, translation: CGSize(width: 10000, height: 10000))
        let resized = state.windows.first(where: { $0.id == browser })!.frame
        precondition(resized.maxX == original.maxX && resized.maxY == original.maxY)

        state.setLayout(.right, for: guest)
        let tiled = state.displayFrame(state.windows.last!)
        precondition(tiled.minX == state.workArea.midX && tiled.maxX == state.workArea.maxX)
        state.setCanvas(CGSize(width: 320, height: 240))
        for window in state.windows { precondition(state.workArea.contains(state.displayFrame(window))) }
        state.setCanvas(.zero)
        precondition(state.canvas.width == 320)
        state.close(guest)
        precondition(state.activeID == browser)
        state.close(browser)
        precondition(state.activeID == nil && state.windows.isEmpty)
        state.focus(UUID())
        state.toggleFullscreen(UUID())
        precondition(state.windows.isEmpty && state.fullscreenID == nil)

        precondition(TahoeAddress.url(for: " example.com/path ")?.absoluteString == "https://example.com/path")
        precondition(TahoeAddress.url(for: "https://example.com")?.scheme == "https")
        precondition(TahoeAddress.url(for: "http://localhost:8080")?.port == 8080)
        for input in ["", "  ", "javascript:alert(1)", "file:///private/test", "ftp://example.com"] {
            precondition(TahoeAddress.url(for: input) == nil)
        }
        let search = TahoeAddress.url(for: "swift ui & windows")!
        precondition(URLComponents(url: search, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "swift ui & windows")
        print("Tahoe window lifecycle, resizing, fullscreen, tiling, rotation and address fixtures passed.")
    }
}
