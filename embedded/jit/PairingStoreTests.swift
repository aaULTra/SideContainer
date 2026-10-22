import Foundation
import CryptoKit

@main
struct PairingStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(JITPairingStore.relativePath)
        func record(_ key: Curve25519.Signing.PrivateKey, identifier: String = "fixture") throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["identifier": identifier,
                "public_key": key.publicKey.rawRepresentation, "private_key": key.rawRepresentation], format: .xml, options: 0)
        }
        let first = try record(Curve25519.Signing.PrivateKey())
        try JITPairingStore.save(first, to: url)
        let savedFirst = try Data(contentsOf: url)
        precondition(savedFirst == first)
        let replacement = try record(Curve25519.Signing.PrivateKey())
        try JITPairingStore.save(replacement, to: url)
        let savedReplacement = try Data(contentsOf: url)
        precondition(savedReplacement == replacement, "JIT must receive the latest pairing, not a stale copied record")
        let legacy = try PropertyListSerialization.data(fromPropertyList: ["HostID": "legacy"], format: .xml, options: 0)
        let wrongKey = Curve25519.Signing.PrivateKey()
        let mismatch = try PropertyListSerialization.data(fromPropertyList: ["identifier":"fixture",
            "private_key": wrongKey.rawRepresentation, "public_key": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation], format: .binary, options: 0)
        for invalid in [legacy, mismatch, try record(wrongKey, identifier: ""), Data("not a plist".utf8)] {
            do { try JITPairingStore.save(invalid, to: url); fatalError("Invalid pairing replaced the active record") }
            catch { }
            let unchanged = try Data(contentsOf: url)
            precondition(unchanged == replacement)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        print("Private pairing handoff: validated replacement, rejected malformed/legacy/mismatched keys, and permissions passed")
    }
}
