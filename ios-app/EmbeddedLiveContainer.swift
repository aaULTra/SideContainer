#if SIDEINSTALLER_EMBEDDED
import Foundation
import Security
import SwiftUI
import UIKit
import Darwin
import UniformTypeIdentifiers

struct EmbeddedCertificateHandoff {
    let report: String
    let activationIssue: String?
    let needsHostUpdate: Bool
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
        let host = try EmbeddedSigningIdentity.host()
        let leaf = try EmbeddedSigningIdentity.certificate(p12: certificate, password: password)
        let needsHostUpdate = !EmbeddedSigningIdentity.permits(leaf, profile: host.profile)
            || ((host.profile["ExpirationDate"] as? Date).map { $0 <= Date() } ?? true)
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
                                          activationIssue: issue, needsHostUpdate: needsHostUpdate)
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
    @State private var passed = false
    @State private var needsRepair = false
    @State private var hasRepairIPA = false
    @State private var pickingIPA = false
    @State private var confirmRepair = false
    @State private var message = "Connect LocalDevVPN, then check signing. The matching certificate is shared automatically; no separate import is needed."

    var body: some View {
        NavigationStack {
            Form {
                Section("LiveContainer signing") {
                    Label(working ? "Checking…" : (passed ? "Ready" : "Signing setup"),
                          systemImage: passed ? "checkmark.circle.fill" : "checkmark.shield")
                    Text(message).textSelection(.enabled)
                    Button("Check signing") { runCheck() }
                        .disabled(working || engine.isRunning || AppRefreshService.shared.isRefreshing)
                    if !working && !passed {
                        Button("Copy details") { UIPasteboard.general.string = message }
                    }
                    if working { ProgressView() }
                }
                if needsRepair {
                    Section("Update signing profile") {
                        Text("The installed profile needs this certificate. Update the same app using the same Apple account; existing apps and data stay in place.")
                        if !hasRepairIPA {
                            Button("Choose this app’s IPA…") { pickingIPA = true }.disabled(working)
                        }
                        Button("Update signing profile") { confirmRepair = true }
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
                        message = "IPA ready. Tap Update signing profile to continue."
                    }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .confirmationDialog("Update this app’s signing profile?", isPresented: $confirmRepair, titleVisibility: .visible) {
                Button("Update signing profile") {
                    start {
                        try await engine.repairEmbeddedHostSigning()
                        passed = false
                        needsRepair = false
                        message = "Update completed. Reopen LiveContainer, then tap Check signing to run the device test."
                    }
                }
            } message: {
                Text("This updates the same app and may close it. Reopen afterwards to finish the signing test.")
            }
        }
    }

    private func updateRepairIPA() { hasRepairIPA = (try? engine.embeddedHostRepairIPA()) != nil }

    private func runCheck() {
        passed = false
        needsRepair = false
        start {
            let result = try await engine.checkEmbeddedHostSigning()
            needsRepair = result.needsRepair
            passed = result.passed
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
            catch { passed = false; needsRepair = false; message = AppRefreshService.text(for: error) }
        }
    }
}
#endif
