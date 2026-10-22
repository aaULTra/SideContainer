// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct SIJITRequest: Codable {
    enum Operation: String, Codable { case prepare, enable, reset }
    let operation: Operation
    let id: UUID
    let group: String
    let pid: Int32?
    let pairing: Data?
    let script: String?
    let forceScript: Bool
    static let key = "SideInstaller.JIT.request"
    var statusKey: String { "SideInstaller.JIT.status." + id.uuidString }
    struct Response: Codable {
        let success: Bool
        let message: String
        static let key = "SideInstaller.JIT.response"
    }
}

// Only retry read-only preflight checks, never DDI installation, debugger
// attachment, or a script which may already have changed the guest's memory.
enum SIJITPreparationStage {
    case reachability, checkingDDI, downloading, mounting, verifying, ready
    func shouldRetry(reason: String, attempt: Int) -> Bool {
        guard attempt == 0, self == .reachability || self == .checkingDDI else { return false }
        return reason.contains("ConnectionReset") || reason.localizedCaseInsensitiveContains("connection reset by peer")
    }
}
