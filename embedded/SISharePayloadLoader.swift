import Foundation
import UniformTypeIdentifiers

enum SISharePayloadLoader {
    enum Payload { case file(URL), url(URL), empty }

    static func load(providers: [NSItemProvider], stagingDirectory: URL?) async throws -> Payload {
        var lastError: Error?
        // Files may vend public.file-url without a public.url representation.
        for provider in providers {
            for type in [UTType.fileURL.identifier, UTType.url.identifier] {
                guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
                do {
                    let item = try await provider.loadItem(forTypeIdentifier: type)
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                        url = URL(string: string)
                    } else if let string = item as? String { url = URL(string: string) }
                    else { url = nil }
                    if let url { return url.isFileURL ? .file(url) : .url(url) }
                } catch { lastError = error }
            }
        }
        // A file representation's temporary URL expires when its callback
        // returns. Copy it into the existing app group before handing it to
        // the host; never retain that temporary URL for a later import.
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .data) == true && UTType($0)?.conforms(to: .url) != true
            }) else { continue }
            guard let stagingDirectory else {
                throw NSError(domain: "SISharePayload", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The shared app group is unavailable. Keep all extensions when signing LC + SI."])
            }
            do {
                let url: URL = try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type) { temporary, error in
                        guard let temporary else {
                            continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                            return
                        }
                        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        do {
                            let fm = FileManager.default
                            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                            var name = (provider.suggestedName as NSString?)?.lastPathComponent ?? temporary.lastPathComponent
                            if name.isEmpty || name == "." || name == ".." { name = temporary.lastPathComponent }
                            if (name as NSString).pathExtension.isEmpty {
                                let ext = temporary.pathExtension.isEmpty ? UTType(type)?.preferredFilenameExtension : temporary.pathExtension
                                if let ext, !ext.isEmpty { name += "." + ext }
                            }
                            let destination = directory.appendingPathComponent(name)
                            let accessing = temporary.startAccessingSecurityScopedResource()
                            defer { if accessing { temporary.stopAccessingSecurityScopedResource() } }
                            try fm.copyItem(at: temporary, to: destination)
                            continuation.resume(returning: destination)
                        } catch {
                            try? FileManager.default.removeItem(at: directory)
                            continuation.resume(throwing: error)
                        }
                    }
                }
                return .file(url)
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        return .empty
    }
}
