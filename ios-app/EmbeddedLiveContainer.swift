#if SIDEINSTALLER_EMBEDDED
import Foundation
import Security
import SwiftUI
import Darwin
import UniformTypeIdentifiers

struct EmbeddedCertificateHandoff {
    let report: String
    let activationIssue: String?
}

struct EmbeddedSigningCheck {
    let needsRepair: Bool
    let message: String
}

/// UI and LiveProcess have different Engine singletons. An OS-held lock also
/// excludes the other process and is automatically released if either dies.
final class EmbeddedRefreshLease {
    private var descriptor: Int32 = -1

    init() throws {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("SideInstaller-operation.lock").path,
                          O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw EngineError.message("Unable to reserve the embedded signing operation.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failedDescriptor = descriptor
            descriptor = -1
            close(failedDescriptor)
            throw EngineError.message("SideInstaller is already installing or refreshing in another process.")
        }
    }

    deinit {
        guard descriptor >= 0 else { return }
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
    static func storeCertificate(config: String, signingTeam: String?) throws -> EmbeddedCertificateHandoff {
        guard let json = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any],
              let encoded = json["certificateData"] as? String,
              let certificate = Data(base64Encoded: encoded),
              let password = json["certificatePassword"] as? String else {
            throw EngineError.message("SideInstaller could not export its signing certificate.")
        }
        let report = try EmbeddedSigningIdentity.report(p12: certificate, password: password, team: signingTeam)
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
        // Keep an incompatible identity staged for an explicit host repair, but
        // never replace LC's active identity with one the installed profile rejects.
        let issue = SIEmbeddedActivateCertificate(certificate, password)
        return EmbeddedCertificateHandoff(report: (issue ?? "Certificate installed in LiveContainer. No separate import is needed.") + "\n\n" + report,
                                          activationIssue: issue)
    }
}

struct EmbeddedLiveContainerBar: View {
    @EnvironmentObject private var engine: Engine
    @State private var showingSetup = false

    var body: some View {
        HStack {
            Button("LiveContainer", systemImage: "arrow.uturn.backward") { SIEmbeddedReturnToHost() }
            Spacer()
            Button("Set up LiveContainer", systemImage: "checkmark.shield") { engine.embeddedSigningSetupPresented = true; showingSetup = true }
        }
        .disabled(engine.isRunning || AppRefreshService.shared.isRefreshing)
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .sheet(isPresented: $showingSetup, onDismiss: { engine.embeddedSigningSetupPresented = false }) { EmbeddedSigningSetupView().environmentObject(engine) }
    }
}

private struct EmbeddedSigningSetupView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    @State private var working = false
    @State private var shownTwoFactor: TwoFactorPhase?
    @State private var checked = false
    @State private var needsRepair = false
    @State private var hasRepairIPA = false
    @State private var pickingIPA = false
    @State private var confirmRepair = false
    @State private var message = "Connect LocalDevVPN, then check signing. SideInstaller will sign in, check this LiveContainer's certificate, activate it when compatible, and run the signing test."

    var body: some View {
        NavigationStack {
            Form {
                Section("LiveContainer signing") {
                    Label(working ? "Checking…" : (checked && !needsRepair ? "Signing test passed" : "Setup and repair"),
                          systemImage: checked && !needsRepair ? "checkmark.circle.fill" : "checkmark.shield")
                    Text(message).textSelection(.enabled)
                    Button("Check and fix signing") { runCheck() }
                        .disabled(working || engine.isRunning || AppRefreshService.shared.isRefreshing)
                    if working { ProgressView() }
                }
                if needsRepair {
                    Section("Repair this installation") {
                        Text("Re-signs this LiveContainer in place with SideInstaller's certificate. Keep the same Apple account/team. Your apps and data stay in the existing installation.")
                        Label(hasRepairIPA ? "Matching repair IPA is ready" : "This build's original combined IPA is needed",
                              systemImage: hasRepairIPA ? "checkmark.circle" : "doc.badge.plus")
                        Button("Choose original combined IPA…") { pickingIPA = true }.disabled(working)
                        Button("Repair signing") { confirmRepair = true }
                            .disabled(working || !hasRepairIPA || engine.isRunning || AppRefreshService.shared.isRefreshing)
                    }
                }
            }
            .navigationTitle("Set up LiveContainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
            .onAppear { updateRepairIPA() }
            .onDisappear { operation?.cancel() }
            .sheet(isPresented: Binding(get: { engine.twoFactor != nil },
                                       set: { if !$0 { engine.cancelTwoFactor() } })) {
                if let phase = engine.twoFactor ?? shownTwoFactor { TwoFactorSheet(phase: phase) }
            }
            .onChange(of: engine.twoFactor) { _, phase in
                if let phase { shownTwoFactor = phase }
            }
            .fileImporter(isPresented: $pickingIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
                switch result {
                case .success(let url):
                    start {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let host = try EmbeddedSigningIdentity.host()
                        let revision = host.bundle.object(forInfoDictionaryKey: "SIEmbeddedSourceRevision") as? String
                        guard let revision, IPALibrary.appInfo(at: url)?.bundleID == EmbeddedSigningIdentity.baseID,
                              IPALibrary.embeddedRevision(at: url) == revision else {
                            throw EngineError.message("Choose the original combined IPA for the build currently installed. A different revision cannot repair this installation.")
                        }
                        await engine.importCustomIPA(from: url)
                        if let error = engine.lastError { throw EngineError.message(error) }
                        updateRepairIPA()
                        message = "Repair IPA ready. Tap Repair signing to continue."
                    }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .confirmationDialog("Repair LiveContainer signing?", isPresented: $confirmRepair, titleVisibility: .visible) {
                Button("Repair signing") {
                    start {
                        try await engine.repairEmbeddedHostSigning()
                        checked = false
                        message = "Host replacement reported completion. Fully close and reopen LiveContainer, then return here and tap Check and fix signing. No manual certificate import is needed."
                    }
                }
            } message: {
                Text("This replaces the running app with the same build, bundle ID and team, and may close it before confirmation. Back up important guest data first. Reopen afterwards to finish the signing test.")
            }
        }
    }

    private func updateRepairIPA() { hasRepairIPA = (try? engine.embeddedHostRepairIPA()) != nil }

    private func runCheck() {
        checked = false
        start {
            let result = try await engine.checkEmbeddedHostSigning()
            needsRepair = result.needsRepair
            checked = true
            message = result.message
            updateRepairIPA()
        }
    }

    private func start(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        operation = Task { @MainActor in
            defer { working = false; operation = nil }
            do { try Task.checkCancellation(); try await action() }
            catch { checked = false; message = AppRefreshService.text(for: error) }
        }
    }
}
#endif
