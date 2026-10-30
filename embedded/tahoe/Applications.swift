import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct TahoeApplicationsView: View {
    @ObservedObject var workspace: TahoeWorkspace
    var filter = ""
    @EnvironmentObject private var model: SharedModel
    var body: some View {
        TahoeSidebar {
            VStack(alignment: .leading, spacing: 14) {
                Text("Favourites").font(.caption).foregroundStyle(.secondary)
                Button { workspace.openBrowser() } label: { Label("Browser", systemImage: "safari") }
                Button { workspace.open(.files) } label: { Label("Documents", systemImage: "folder") }
                Button { workspace.showManagement = true } label: { Label("Manage Native Apps", systemImage: "square.stack.3d.up") }
                Spacer()
            }.font(.system(size: 13)).padding()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Applications").font(.title2.bold())
                    Text("Web apps are the primary workspace. Import native IPAs and configure signing in LiveContainer management.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open a browser window") { workspace.openBrowser() }.buttonStyle(TahoeControlStyle())
                    Divider()
                    Text("Installed Native Apps").font(.headline)
                    let apps = model.apps.filter { !$0.uiIsHidden && (filter.isEmpty || $0.displayName.localizedCaseInsensitiveContains(filter)) }
                    if apps.isEmpty { Text("No matching native apps. Use Manage Native Apps to import an IPA.").foregroundStyle(.secondary) }
                    ForEach(apps, id: \.self) { app in
                        Button {
                            workspace.showSpotlight = false
                            Task { await workspace.launch(app) }
                        } label: {
                            HStack {
                                Image(systemName: app.uiIsLocked ? "lock.app.fill" : "app.fill").font(.title2).foregroundStyle(TahoeDesign.accent)
                                VStack(alignment: .leading) { Text(app.displayName); Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if app.isSigningInProgress { ProgressView(value: app.signProgress).frame(width: 70) }
                                Image(systemName: "arrow.up.forward")
                            }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(workspace.launching)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(.plain)
    }
}

struct TahoeSettingsView: View {
    @AppStorage("TahoeDarkAppearance") private var darkAppearance = false
    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Dark appearance", isOn: $darkAppearance)
                Text("Desktop effects also respect iPad accessibility settings for Reduce Motion and Reduce Transparency.")
            }
            Section("Fullscreen") {
                Text("Fullscreen keeps other windows loaded. Use Window → Performance Fullscreen to explicitly unload other browser pages. They reload when resumed; unsaved page state and back history are lost.")
            }
            Section("Native Apps") {
                Button("Open LiveContainer & SideInstaller") { TahoeWorkspace.shared.showManagement = true }
                Text("Begin with a non-JIT guest. Native hosting, focus and resizing need testing on your iPad. JIT configuration remains in the original management interface.")
            }
            Section("Development Status") {
                Text("This is the first desktop integration. Downloads, persistent workspaces, pinned web apps and the iPhone extended workspace are not implemented yet.")
            }
        }.font(.system(size: 13))
    }
}

@MainActor
private final class TahoeFiles: ObservableObject {
    @Published var entries: [URL] = []
    @Published var directory: URL
    @Published var error: String?
    let root: URL
    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TahoeDesktop/Files", isDirectory: true)
        directory = root
        refresh()
    }
    func refresh() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch { self.error = error.localizedDescription }
    }
    func createFolder() {
        var name = "New Folder"
        var count = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { name = "New Folder \(count)"; count += 1 }
        do { try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                // Existing files are never silently replaced.
                try FileManager.default.copyItem(at: url, to: destination)
            } catch { self.error = error.localizedDescription }
        }
        refresh()
    }
    func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

struct TahoeFilesView: View {
    @StateObject private var files = TahoeFiles()
    @State private var importing = false
    @State private var preview: URL?
    var body: some View {
        TahoeSidebar {
            VStack(alignment: .leading, spacing: 14) {
                Text("Favourites").font(.caption).foregroundStyle(.secondary)
                Button { files.directory = files.root; files.refresh() } label: { Label("Documents", systemImage: "folder") }
                Text("Files imported here are copies in this desktop's Documents folder.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding()
        } content: {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        if files.directory != files.root { files.directory.deleteLastPathComponent(); files.refresh() }
                    } label: { Image(systemName: "chevron.left") }.disabled(files.directory == files.root).accessibilityLabel("Parent folder")
                    Text(files.directory == files.root ? "Documents" : files.directory.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("New Folder") { files.createFolder() }
                    Button("Import…") { importing = true }
                }.font(.system(size: 13)).padding(12)
                Divider()
                List(files.entries, id: \.self) { url in
                    Button {
                        if files.isDirectory(url) { files.directory = url; files.refresh() }
                        else { preview = url }
                    } label: {
                        Label(url.lastPathComponent, systemImage: files.isDirectory(url) ? "folder.fill" : "doc.fill")
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
                if files.entries.isEmpty { Text("This folder is empty. Import files to get started.").font(.callout).foregroundStyle(.secondary).padding() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): files.importFiles(urls); case .failure(let error): files.error = error.localizedDescription }
        }
        .quickLookPreview($preview)
        .alert("File operation failed", isPresented: Binding(get: { files.error != nil }, set: { if !$0 { files.error = nil } })) {
            Button("OK") { files.error = nil }
        } message: { Text(files.error ?? "") }
    }
}
