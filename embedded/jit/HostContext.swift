import Foundation

/// LC_HOME_PATH is set by LiveContainerMain even for the host UI. Only the
/// bootstrap state and actual main bundle distinguish a coordinator from a guest.
struct SIJITHostContext {
    let currentBundleURL: URL
    let bootstrapBundleURL: URL?
    let isCombinedBuild: Bool
    let isLiveProcess: Bool
    let isEmbeddedInstaller: Bool
    let guestID: String?

    var canCoordinateJIT: Bool {
        guard isCombinedBuild, !isLiveProcess, !isEmbeddedInstaller,
              guestID?.isEmpty != false, let bootstrapBundleURL else { return false }
        return currentBundleURL.standardizedFileURL.resolvingSymlinksInPath()
            == bootstrapBundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}
