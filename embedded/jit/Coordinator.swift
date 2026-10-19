// SPDX-License-Identifier: GPL-3.0-or-later
// Appended to LCUtilsExtensions.swift by the checked host adaptation so this
// source is compiled by the existing explicit Xcode project target.
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
        status = "Pairing file imported. Device preparation must be checked again."
    }

    func prepare() async throws { _ = try await run(.prepare) }
    func enable(pid: Int, script: String?) async throws {
        guard pid > 0, pid <= Int(Int32.max), pid != Int(getpid()) else {
            throw Self.error("Built-in JIT must target the guest LiveProcess, not the LiveContainer UI.")
        }
        _ = try await run(.enable, pid: Int32(pid), script: script)
    }
    func reset() async throws { _ = try await run(.reset) }

    private func run(_ operation: SIJITRequest.Operation, pid: Int32? = nil, script: String? = nil) async throws -> String {
        try Task.checkCancellation()
        guard !busy else { throw Self.error("Another built-in JIT session is active. Finish or cancel it first.") }
        guard #available(iOS 17.4, *), getenv("LC_HOME_PATH") == nil else {
            throw Self.error("Built-in JIT must be started by the installed LiveContainer host.")
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
        let pairing = operation == .reset ? nil : try Data(contentsOf: pairingURL)
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
        status = operation == .enable ? "Starting JIT for guest PID \(pid ?? 0)…" : "Starting device preparation…"
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
        case .failure(let error): status = error.localizedDescription
        }
        continuation.resume(with: result)
    }
}

struct SIBuiltInJITSettings: View {
    @ObservedObject private var jit = SIBuiltInJIT.shared
    @State private var importing = false
    @AppStorage("SIForceJITScript", store: LCUtils.appGroupUserDefault) private var forceScript = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(jit.status).font(.footnote).textSelection(.enabled)
            Text("Enable Developer Mode and connect LocalDevVPN. Keep all extensions when signing. Uses the guest's configured script, or universal.js by default. Built-in JIT launches guests in LiveProcess; classic mode is unsupported.")
                .font(.footnote)
            Button(jit.hasPairing ? "Replace JIT pairing file" : "Import JIT pairing file") { importing = true }
                .disabled(jit.busy)
            Button("Prepare JIT device") { Task { do { try await jit.prepare() } catch { jit.show(error) } } }.disabled(jit.busy || !jit.hasPairing)
            Button("Reset Developer Disk Image cache") { Task { do { try await jit.reset() } catch { jit.show(error) } } }.disabled(jit.busy)
            Toggle("Force configured JIT script", isOn: $forceScript).disabled(jit.busy)
            Text("Force script bypasses TXM detection. Use it only when the guest requires the script on this device.").font(.caption)
            if jit.busy { Button("Cancel JIT", role: .destructive) { jit.cancel() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do { try jit.importPairing(result.get()) }
            catch { jit.show(error) }
        }
    }
}

extension SIBuiltInJIT {
    func show(_ error: Error) { status = error.localizedDescription }
}
