// SPDX-License-Identifier: AGPL-3.0-or-later
// Copied into the UI framework's synchronized Xcode group by the checked adaptation.
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin

@objc private protocol SIJITExtensionFactory {
    @objc(extensionWithIdentifier:error:)
    func make(identifier: String) throws -> AnyObject
}
@objc private protocol SIJITExtension {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func begin(items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(setRequestCompletionBlock:)
    func onCompletion(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func onCancellation(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func onInterruption(_ block: @escaping (NSUUID?) -> Void)
    @objc(cancelExtensionRequestWithIdentifier:)
    func cancel(identifier: NSUUID)
}

@MainActor
final class SIBuiltInJIT: ObservableObject {
    static let shared = SIBuiltInJIT()
    @Published private(set) var status = "Import a pairing file, then prepare the device."
    @Published private(set) var busy = false
    @Published private(set) var prepared = false
    private var helper: AnyObject?
    private var requestID: NSUUID?
    private var request: SIJITRequest?
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Timer?
    private var deadline = Date.distantFuture

    nonisolated static var selected: Bool { LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType") == 7 }
    private var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT/pairingFile.plist")
    }
    var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "SideInstaller.BuiltInJIT", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func importPairing(_ url: URL) throws {
        guard !busy else { throw Self.error("Wait for the active JIT operation to finish.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !plist.isEmpty else { throw Self.error("Select a valid pairing plist.") }
        try FileManager.default.createDirectory(at: pairingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
        prepared = false
        status = "Pairing file saved. Tap Prepare device once, or run a JIT app to prepare automatically."
    }

    // Readiness is deliberately limited to this host process/boot. A replacement
    // pairing file, reset, failed/cancelled operation or relaunch invalidates it.
    func prepare(force: Bool = false) async throws {
        guard !busy else { throw Self.error("Another built-in JIT session is active.") }
        if prepared && !force { return }
        prepared = false
        _ = try await run(.prepare)
        prepared = true
    }
    func enable(pid: Int, script: String?) async throws {
        guard pid > 0, pid <= Int(Int32.max), pid != Int(getpid()) else {
            throw Self.error("Built-in JIT must target the guest LiveProcess, not the LiveContainer UI.")
        }
        guard prepared else { throw Self.error("Prepare the device from LiveContainer before starting the guest.") }
        do { _ = try await run(.enable, pid: Int32(pid), script: script) }
        catch { prepared = false; throw error }
    }
    func reset() async throws {
        guard !busy else { throw Self.error("Wait for the active JIT operation to finish.") }
        prepared = false
        _ = try await run(.reset)
    }

    private func run(_ operation: SIJITRequest.Operation, pid: Int32? = nil, script: String? = nil) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw Self.error("Another built-in JIT session is active. Finish or cancel it first.") }
        guard #available(iOS 17.4, *) else {
            throw Self.error("Built-in JIT needs iOS 17.4 or later.")
        }
        let context = SIJITHostContext(
            currentBundleURL: Bundle.main.bundleURL,
            bootstrapBundleURL: UserDefaults.lcMainBundle()?.bundleURL,
            isCombinedBuild: Bundle.main.object(forInfoDictionaryKey: "SIEmbeddedBuild") as? Bool == true,
            isLiveProcess: UserDefaults.isLiveProcess(),
            isEmbeddedInstaller: UserDefaults.isSideStore(),
            guestID: UserDefaults.lcGuestAppId())
        guard context.canCoordinateJIT else {
            throw Self.error("Open the installed LiveContainer + SI app's Settings to prepare JIT, then launch the guest from its Apps page. Guest apps and LiveProcess cannot start this helper themselves.")
        }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let identifier = Bundle(url: plugins.appendingPathComponent("SIJITHelper.appex"))?.bundleIdentifier,
              let process = Bundle(url: plugins.appendingPathComponent("LiveProcess.appex")),
              let executable = process.executablePath,
              let xml = LCSharedUtils.embeddedEntitlements(atPath: executable),
              let entitlements = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any],
              entitlements["get-task-allow"] as? Bool == true else {
            throw Self.error("Missing JIT helper, LiveProcess or get-task-allow. Reinstall this build and keep all extensions.")
        }
        guard let group = LCSharedUtils.appGroupID(),
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else {
            throw Self.error("This installation's app group is unavailable.")
        }
        let pairing: Data?
        if operation == .reset { pairing = nil }
        else {
            guard hasPairing else { throw Self.error("Open Settings → Built-in JIT setup and import this device’s pairing file once.") }
            pairing = try Data(contentsOf: pairingURL)
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let factory = NSClassFromString("NSExtension") else { throw Self.error("The extension API is unavailable.") }
        let found = try unsafeBitCast(factory as AnyObject, to: SIJITExtensionFactory.self).make(identifier: identifier)
        let message = SIJITRequest(operation: operation, id: UUID(), group: group, pid: pid,
                                   pairing: pairing, script: script,
                                   forceScript: LCUtils.appGroupUserDefault.bool(forKey: "SIForceJITScript"))
        let data = try JSONEncoder().encode(message)
        busy = true
        status = operation == .enable ? "Starting JIT for guest PID \(pid ?? 0)…" : (operation == .reset ? "Resetting Developer Disk Image cache…" : "Starting device preparation…")
        helper = found
        request = message
        deadline = Date().addingTimeInterval(operation == .enable ? 180 : 600)
        let shim = unsafeBitCast(found, to: SIJITExtension.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                shim.onCompletion { [weak self] _, items in
                    let payload = (items?.first as? NSExtensionItem)?.userInfo?[SIJITRequest.Response.key] as? Data
                    DispatchQueue.main.async {
                        guard let self, self.request?.id == message.id else { return }
                        guard let payload, let result = try? JSONDecoder().decode(SIJITRequest.Response.self, from: payload) else {
                            self.finish(.failure(Self.error("The JIT helper returned no result.")))
                            return
                        }
                        self.finish(result.success ? .success(result.message) : .failure(Self.error(result.message)))
                    }
                }
                shim.onCancellation { [weak self] _, error in
                    DispatchQueue.main.async {
                        guard self?.request?.id == message.id else { return }
                        self?.finish(.failure(error ?? Self.error("The JIT helper was cancelled.")))
                    }
                }
                shim.onInterruption { [weak self] _ in
                    DispatchQueue.main.async {
                        guard self?.request?.id == message.id else { return }
                        self?.finish(.failure(Self.error("The JIT helper stopped unexpectedly. Close the guest and try again.")))
                    }
                }
                let item = NSExtensionItem()
                item.userInfo = [SIJITRequest.key: data]
                shim.begin(items: [item]) { [weak self] identifier in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        guard self.request?.id == message.id else {
                            if let identifier { shim.cancel(identifier: identifier) }
                            return
                        }
                        guard let identifier else {
                            self.finish(.failure(Self.error("iOS could not start the JIT helper. Keep all extensions when signing.")))
                            return
                        }
                        self.requestID = identifier
                    }
                }
                timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func poll() {
        guard let request else { return }
        if let update = UserDefaults(suiteName: request.group)?.string(forKey: request.statusKey) { status = update }
        if Date() >= deadline {
            cancel(reason: "JIT timed out. Close the guest before retrying. Check LocalDevVPN, pairing and the guest's script protocol.")
        }
    }

    func cancel(reason: String = "JIT cancelled. Close the guest before retrying.") {
        if let request {
            UserDefaults(suiteName: request.group)?.set(true, forKey: request.statusKey + ".cancel")
        }
        if let helper, let requestID {
            unsafeBitCast(helper, to: SIJITExtension.self).cancel(identifier: requestID)
        }
        finish(.failure(Self.error(reason)))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.invalidate()
        timer = nil
        if let request { UserDefaults(suiteName: request.group)?.removeObject(forKey: request.statusKey) }
        request = nil
        requestID = nil
        helper = nil
        busy = false
        switch result {
        case .success(let message): status = message
        case .failure(let error): prepared = false; status = error.localizedDescription
        }
        continuation.resume(with: result)
    }
}

struct SIBuiltInJITSettings: View {
    @ObservedObject private var jit = SIBuiltInJIT.shared
    @State private var importing = false
    @AppStorage("SIForceJITScript", store: LCUtils.appGroupUserDefault) private var forceScript = false
    var body: some View {
        Form {
            Section {
                Label(jit.prepared ? "Device prepared" : (jit.hasPairing ? "Pairing file saved" : "Pairing file needed"),
                      systemImage: jit.prepared ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                Text(jit.status).font(.footnote).textSelection(.enabled)
                if jit.busy { ProgressView() }
            } footer: {
                Text("Preparation checks the device connection and Developer Disk Image. Each app still needs its own JIT session when launched.")
            }
            Section {
                Button(jit.hasPairing ? "Replace pairing file…" : "Import pairing file…") { importing = true }
                    .disabled(jit.busy)
                Button(jit.prepared ? "Check device again" : "Prepare device") {
                    Task { do { try await jit.prepare(force: true) } catch { jit.show(error) } }
                }.disabled(jit.busy || !jit.hasPairing)
                if jit.busy { Button("Cancel", role: .destructive) { jit.cancel() } }
            } footer: {
                Text("Import this device’s pairing file once. Enable Developer Mode and connect LocalDevVPN. Running a JIT app prepares the device automatically if needed; you don’t need to select the JIT enabler again.")
            }
            Section {
                Toggle("Force configured JIT script", isOn: $forceScript).disabled(jit.busy)
            } footer: {
                Text("Uses the app’s JIT Launch Script, or universal.js when none is configured. For Husk, select its husk-jit.js script in the app’s settings and enable this switch. Keep Compatibility Mode off: built-in JIT uses LiveProcess.")
            }
            Section {
                Button("Reset Developer Disk Image cache", role: .destructive) {
                    Task { do { try await jit.reset() } catch { jit.show(error) } }
                }.disabled(jit.busy)
            } footer: {
                Text("Use only to troubleshoot a failed download or mount. This does not replace your pairing file or enable JIT.")
            }
        }
        // Form’s automatic button style treats an entire row as one action.
        // Keep actions as separate rows and give them independent hit targets.
        .buttonStyle(.borderless)
        .navigationTitle("Built-in JIT setup")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): do { try jit.importPairing(url) } catch { jit.show(error) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { jit.show(error) }
            }
        }
    }
}

extension SIBuiltInJIT {
    func show(_ error: Error) { status = error.localizedDescription }
}
