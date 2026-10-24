import Foundation
import UniformTypeIdentifiers
import Combine

// The actual ShareModels.swift is compiled into this native fixture. Only
// its containing-app lookup needs a stand-in; loader behaviour stays real.
enum LCSharedUtils { static func appGroupPath() -> URL? { nil } }
final class ShareMenuState: ObservableObject {
    @Published var payload = SharePayload()
}

@main
struct SharePayloadTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
        let temporary = root.appendingPathComponent("provider-temp.zip")
        let bytes = Data("fixture IPA bytes".utf8)
        try bytes.write(to: temporary)
        let fileOnly = NSItemProvider()
        fileOnly.suggestedName = "Game & test.ipa"
        fileOnly.registerFileRepresentation(forTypeIdentifier: UTType.zip.identifier,
                                            fileOptions: [], visibility: .all) { callback in
            callback(temporary, false, nil)
            return nil
        }
        precondition(!fileOnly.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        let file = try await SISharePayloadLoader.load(providers: [fileOnly], stagingDirectory: inbox)
        guard case .file(let staged) = file else { fatalError("File-only IPA must produce an import action") }
        precondition(staged.lastPathComponent == "Game & test.ipa")
        precondition(staged.deletingLastPathComponent().deletingLastPathComponent() == inbox)
        try fm.removeItem(at: temporary)
        let copiedBytes = try Data(contentsOf: staged)
        precondition(copiedBytes == bytes, "Do not retain the provider's temporary URL")
        let menu = ShareMenuState()
        var publications = 0
        let token = menu.objectWillChange.sink { publications += 1 }
        menu.payload.kind = .file(staged)
        precondition(publications == 1, "Recognising an IPA must refresh the import menu")
        menu.payload.kind = .failed("fixture failure")
        precondition(publications == 2, "A loading failure must refresh the error display")
        token.cancel()

        let website = URL(string: "https://example.com/a?value=1&other=2")!
        let link = NSItemProvider(item: website as NSURL, typeIdentifier: UTType.url.identifier)
        guard case .url(let returned) = try await SISharePayloadLoader.load(providers: [link], stagingDirectory: nil)
        else { fatalError("Web sharing must remain available without staging") }
        precondition(returned == website)
        guard case .empty = try await SISharePayloadLoader.load(providers: [], stagingDirectory: inbox)
        else { fatalError("An empty request must remain empty") }

        do {
            _ = try await SISharePayloadLoader.load(providers: [fileOnly], stagingDirectory: nil)
            fatalError("Missing shared storage must produce an error")
        } catch { precondition(!error.localizedDescription.isEmpty) }
        print("File-only IPA and web share payload checks passed")
    }
}
