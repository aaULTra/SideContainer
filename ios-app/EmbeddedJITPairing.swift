#if SIDEINSTALLER_EMBEDDED
import Foundation

@MainActor
enum EmbeddedJITPairing {
    /// Uses the bootstrap's captured real app-group path, not a guest home or
    /// newly-created preference suite (both are redirected by LC guest hooks).
    static func sendCurrent(activate: Bool = false) throws {
        guard let destination = SIEmbeddedJITPairingURL() else {
            throw NSError(domain: "SideInstaller.JITPairing", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "LiveContainer’s pairing handoff is unavailable. Reopen the updated combined app."])
        }
        let data = try Data(contentsOf: PrivateStore.pairingFile)
        try JITPairingStore.save(data, to: destination)
        if activate && !SIEmbeddedUseJITPairing() {
            throw NSError(domain: "SideInstaller.JITPairing", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Pairing was saved. In LiveContainer’s Built-in JIT setup, tap Use built-in SideInstaller pairing."])
        }
    }

    /// A handoff failure must never turn a successful pair/install into failure.
    static func syncIfAvailable() -> String? {
        guard FileManager.default.fileExists(atPath: PrivateStore.pairingFile.path) else { return nil }
        do { try sendCurrent(); return nil }
        catch { return "LiveContainer JIT pairing was not synced: " + error.localizedDescription }
    }
}
#endif
