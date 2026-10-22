import Foundation

@main
struct HostContextTests {
    static let host = URL(fileURLWithPath: "/Applications/LiveContainer.app")

    static func main() {
        // Reproduce upstream's normal host startup environment. Its presence
        // must not reject the coordinator as the old getenv guard did.
        precondition(ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil)
        let host = Self.host
        func context(current: URL = HostContextTests.host, bootstrap: URL? = HostContextTests.host,
                     combined: Bool = true, live: Bool = false,
                     installer: Bool = false, guest: String? = nil) -> SIJITHostContext {
            SIJITHostContext(currentBundleURL: current, bootstrapBundleURL: bootstrap,
                             isCombinedBuild: combined, isLiveProcess: live,
                             isEmbeddedInstaller: installer, guestID: guest)
        }
        precondition(context().canCoordinateJIT, "Host with LC_HOME_PATH must be accepted")
        precondition(context(guest: "").canCoordinateJIT)
        precondition(context(current: host.appendingPathComponent("../LiveContainer.app")).canCoordinateJIT)
        precondition(!context(live: true).canCoordinateJIT, "LiveProcess cannot coordinate its own debugger")
        precondition(!context(installer: true).canCoordinateJIT, "Embedded SideInstaller is not the host UI")
        precondition(!context(guest: "com.example.husk").canCoordinateJIT)
        precondition(!context(current: URL(fileURLWithPath: "/Documents/Apps/Husk.app")).canCoordinateJIT,
                     "Classic guests must be rejected even when they share the host process")
        precondition(!context(bootstrap: nil).canCoordinateJIT)
        precondition(!context(combined: false).canCoordinateJIT)
        print("JIT host context checks passed, including host LC_HOME_PATH and rejected guest/extension contexts")
    }
}
