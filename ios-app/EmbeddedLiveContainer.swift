#if SIDEINSTALLER_EMBEDDED
import Foundation
import Security
import SwiftUI
import Darwin

/// UI and LiveProcess have different Engine singletons. An OS-held lock also
/// excludes the other process and is automatically released if either dies.
final class EmbeddedRefreshLease {
    private let descriptor: Int32

    init() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("SideInstaller-operation.lock").path,
                          O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw EngineError.message("Unable to reserve the embedded signing operation.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw EngineError.message("SideInstaller is already installing or refreshing in another process.")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// ObjC entry point called by LiveContainer's existing LiveProcess transport.
/// The transport does not sign or install anything: this delegates to the same
/// service used by SideInstaller's apps page and standalone App Intent.
@MainActor
@objc(SIEmbeddedBridge)
final class SIEmbeddedBridge: NSObject {
    private static var refreshTask: Task<Void, Never>?

    @objc(refreshAllWithProgress:completion:)
    static func refreshAll(progress: @escaping (Double) -> Void,
                           completion: @escaping (String?, String?) -> Void) {
        guard refreshTask == nil else {
            completion(nil, "Another embedded refresh is already running.")
            return
        }
        refreshTask = Task {
            defer { refreshTask = nil }
            guard UserDefaults.standard.bool(forKey: "hasAcceptedTOS"),
                  UserDefaults.standard.bool(forKey: "hasCompletedAccountSetup") else {
                completion(nil, "Open the built-in SideInstaller and complete its initial setup first.")
                return
            }
            var needsAuthentication = false
            let authenticationMonitor = Task { @MainActor in
                guard SIEmbeddedIsLiveProcess() else { return }
                while !Task.isCancelled {
                    if Engine.shared.twoFactor != nil {
                        needsAuthentication = true
                        Engine.shared.cancelTwoFactor()
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            defer { authenticationMonitor.cancel() }
            do {
                let result = try await AppRefreshService.shared.refreshAll { jobs, _ in
                    let completed = jobs.filter {
                        switch $0.state {
                        case .done, .failed: return true
                        default: return false
                        }
                    }.count
                    progress(Double(completed) / Double(max(1, jobs.count)))
                }
                progress(1)
                completion(result.dialog, nil)
            } catch {
                completion(nil, needsAuthentication
                    ? "Apple requires two-factor authentication. Open the built-in SideInstaller, sign in there, then retry the Shortcut."
                    : AppRefreshService.text(for: error))
            }
        }
    }

    @objc(cancelRefresh)
    static func cancelRefresh() { refreshTask?.cancel() }

    /// Keychain hand-off stays within this combined app's access groups. Apple
    /// account passwords and developer-session tokens are never handed to LC.
    static func storeCertificate(config: String, signingTeam: String?) throws {
        guard let team = signingTeam, let host = SIEmbeddedHostTeam(), team == host else {
            throw EngineError.message("The signed-in team must match this LiveContainer's signing team before sharing its certificate.")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
              let encoded = json["certificateData"] as? String,
              let certificate = Data(base64Encoded: encoded),
              let password = json["certificatePassword"] as? String else {
            throw EngineError.message("SideInstaller could not export its signing certificate.")
        }
        for (account, data) in [("signingCertificate", certificate),
                                ("signingCertificatePassword", Data(password.utf8))] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.aault.livecontainer.sideinstaller",
                kSecAttrAccount as String: account,
            ]
            let status = SecItemUpdate(query as CFDictionary,
                                      [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let added = SecItemAdd(add as CFDictionary, nil)
                guard added == errSecSuccess else {
                    throw EngineError.message("Certificate Keychain write failed (\(added)).")
                }
            } else if status != errSecSuccess {
                throw EngineError.message("Certificate Keychain update failed (\(status)).")
            }
        }
    }
}

struct EmbeddedLiveContainerBar: View {
    @EnvironmentObject private var engine: Engine
    @State private var working = false
    @State private var message: String?

    var body: some View {
        HStack {
            Button("Back to LiveContainer", systemImage: "arrow.uturn.backward") {
                SIEmbeddedReturnToHost()
            }
            .disabled(engine.isRunning || AppRefreshService.shared.isRefreshing || working)
            Spacer()
            Button(working ? "Sharing…" : "Share signing certificate") {
                working = true
                Task { @MainActor in
                    defer { working = false }
                    do {
                        try await engine.shareCertificateWithLiveContainer()
                        message = "Certificate shared. Return to LiveContainer → Settings → Import Certificate from SideInstaller."
                    } catch { message = AppRefreshService.text(for: error) }
                }
            }
            .disabled(working || engine.isRunning || AppRefreshService.shared.isRefreshing)
        }
        .font(.footnote)
        .padding()
        .background(.regularMaterial)
        .alert("LiveContainer + SideInstaller", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
    }
}
#endif
