// SPDX-License-Identifier: GPL-3.0-or-later
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
