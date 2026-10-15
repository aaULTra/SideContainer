import AppIntents

struct SideInstallerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllAppsIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Refresh \(.applicationName) apps",
                "Refresh my \(.applicationName) apps",
                "Refresh apps with \(.applicationName)",
            ],
            shortTitle: "Refresh All Apps",
            systemImageName: "arrow.triangle.2.circlepath")
    }
}
