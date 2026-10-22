import Foundation
import CryptoKit

/// Private transport shared only by the embedded installer and its LC host.
/// No keys are placed in URLs, preferences, notifications or logs.
enum JITPairingStore {
    static let relativePath = "SideInstaller/JIT/pairing.plist"

    static func validate(_ data: Data) throws {
        guard let record = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = record["identifier"] as? String, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let secret = record["private_key"] as? Data, secret.count == 32,
              let publicKey = record["public_key"] as? Data, publicKey.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret),
              key.publicKey.rawRepresentation == publicKey else {
            throw NSError(domain: "SideInstaller.JITPairing", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This file has no valid Remote Pairing key pair. Generate a pairing file in the built-in SideInstaller on this device."])
        }
    }

    static func save(_ data: Data, to url: URL) throws {
        try validate(data)
        if (try? Data(contentsOf: url)) == data { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var privateURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateURL.setResourceValues(values)
    }
}
