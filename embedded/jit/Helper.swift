// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import StikJIT

@objc(SIJITHelperHandler)
final class SIJITHelperHandler: NSObject, NSExtensionRequestHandling {
    // StikJIT's synchronous session and script must stay on one queue.
    private static let queue = DispatchQueue(label: "SideInstaller.JIT.debugger")

    func beginRequest(with context: NSExtensionContext) {
        let payload = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SIJITRequest.key] as? Data
        Self.queue.async {
            let response: SIJITRequest.Response
            do {
                guard let payload else { throw Self.error("No JIT request was supplied.") }
                let request = try JSONDecoder().decode(SIJITRequest.self, from: payload)
                response = try Self.execute(request)
            } catch {
                response = .init(success: false, message: error.localizedDescription)
            }
            let item = NSExtensionItem()
            item.userInfo = [SIJITRequest.Response.key: try! JSONEncoder().encode(response)]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func execute(_ request: SIJITRequest) throws -> SIJITRequest.Response {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: request.group) != nil,
              let defaults = UserDefaults(suiteName: request.group) else {
            throw error("The JIT helper cannot access this installation's app group. Keep all extensions when signing.")
        }
        func report(_ message: String) {
            // Only public status is shared. Pairing bytes and scripts are never logged.
            defaults.set(message, forKey: request.statusKey)
        }
        let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = DDIPaths.default(in: root)
        if request.operation == .reset {
            try StikJIT.resetCachedDDI(at: paths)
            return .init(success: true, message: "Developer Disk Image cache reset.")
        }
        guard let pairing = request.pairing, !pairing.isEmpty else { throw error("Import a pairing file first.") }
        let temporary = root.appendingPathComponent("pairing-\(request.id).plist")
        // A previous interrupted helper may not have executed its defer.
        for old in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where old.lastPathComponent.hasPrefix("pairing-") && old.pathExtension == "plist" {
            try? FileManager.default.removeItem(at: old)
        }
        try pairing.write(to: temporary, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: temporary) }
        // The framework has blocking APIs without cooperative cancellation.
        // An independent watchdog ends only this disposable debugger process.
        // The guest may need to be closed after an interrupted debug session.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let deadline = Date().addingTimeInterval(request.operation == .enable ? 180 : 600)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler {
            if defaults.bool(forKey: request.statusKey + ".cancel") || Date() >= deadline {
                try? FileManager.default.removeItem(at: temporary)
                defaults.removeObject(forKey: request.statusKey + ".cancel")
                _exit(73)
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        var stage = SIJITPreparationStage.reachability
        var stageName = "Checking device connection"
        func stageReport(_ message: String) { stageName = message; report(message) }
        let preparation: (StikJIT.PreparationStage) -> Void = { update in
            switch update {
            case .checkingReachability: stage = .reachability; stageReport("Checking LocalDevVPN…")
            case .checkingDDI: stage = .checkingDDI; stageReport("Checking Developer Disk Image…")
            case .downloadingDDI(let fraction, _): stage = .downloading; stageReport("Downloading Developer Disk Image: \(Int(fraction * 100))%")
            case .mountingDDI(let fraction): stage = .mounting; stageReport("Mounting Developer Disk Image: \(Int(fraction * 100))%")
            case .verifyingDDI: stage = .verifying; stageReport("Verifying Developer Disk Image…")
            case .ready: stage = .ready; stageReport("Device prepared. Waiting for the guest's JIT protocol…")
            @unknown default: stage = .verifying; stageReport("Preparing JIT device…")
            }
        }
        if request.operation == .prepare {
            for attempt in 0...1 {
                switch StikJIT.prepareDevice(pairingFile: temporary, paths: paths, progress: preparation) {
                case .ready(let security):
                    let txm = security.isTXMPresent.map { $0 ? "present" : "absent" } ?? "unknown"
                    return .init(success: true, message: "Device prepared (TXM \(txm)). Run your app from Apps; no need to select or prepare again.")
                case .unreachable(let reason), .preparationFailed(let reason):
                    if stage.shouldRetry(reason: reason, attempt: attempt) {
                        report("Device closed the preflight connection. Reconnecting once…")
                        // No guest exists yet, and no install/attach/script is retried.
                        Thread.sleep(forTimeInterval: 0.5)
                        continue
                    }
                    throw error("\(stageName) failed. \(reason)\nCheck LocalDevVPN and that the pairing file belongs to this device. JIT was not started.")
                @unknown default: throw error("StikJIT returned an unknown preparation result.")
                }
            }
            throw error("Device preparation did not complete.")
        }
        guard let pid = request.pid, pid > 0, pid != getpid() else { throw error("Invalid guest PID.") }
        let script: StikJIT.Script
        if let encoded = request.script, !encoded.isEmpty {
            guard let bytes = Data(base64Encoded: encoded), String(data: bytes, encoding: .utf8) != nil else {
                throw error("The guest's JIT script is not valid base64 UTF-8.")
            }
            script = .customBase64(encoded)
        } else {
            script = .universal
        }
        // The host prepares before creating the guest (a DDI download can take
        // minutes). Repeating preparation here opens another RSD session while
        // the guest is already on its short debugger startup deadline.
        stageName = "Connecting debugger to guest PID \(pid)"
        do {
            try StikJIT.enableJITForPreparedDevice(targetPID: pid, pairingFile: temporary,
                                 script: script, forceScript: request.forceScript,
                                 progress: { message in
                                     // Framework stages are public fixed messages. Do not publish
                                     // arbitrary guest-provided JavaScript log contents.
                                     if message == "Opening device tunnel…" || message == "Connecting debug server…" || message == "Negotiating debugger…" {
                                         stageName = message
                                     } else {
                                         stageName = "Running guest JIT protocol (PID \(pid))"
                                     }
                                     report(stageName)
                                 })
        } catch {
            throw Self.error("\(stageName) failed. \(error.localizedDescription)\nNo debugger/script retry was attempted. Close the guest before retrying. If this repeats, check LocalDevVPN, pairing, and the app’s JIT Launch Script.")
        }
        return .init(success: true, message: "Guest PID \(pid): JIT session completed and debugger detached.")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SIJITHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
