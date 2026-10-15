import AppIntents
import Foundation

struct RefreshAllAppsIntent: AppIntent, ProgressReportingIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Re-signs and refreshes your sideloaded apps before they expire.")
    static var openAppWhenRun = false

    private enum Event: Sendable {
        case finished(RefreshAllResult)
        case deadline
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentProgress = progress
        intentProgress.totalUnitCount = 1
        intentProgress.completedUnitCount = 0
        let deadline = ContinuousClock.now + .seconds(27)

        // Both children belong to this invocation. Foreground continuation keeps
        // the same refresh alive; it never starts discovery or signing twice.
        let result = try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask { @MainActor in
                let result = try await AppRefreshService.shared.refreshAll { jobs, _ in
                    intentProgress.totalUnitCount = Int64(max(1, jobs.count))
                    intentProgress.completedUnitCount = Int64(jobs.filter {
                        switch $0.state {
                        case .done, .failed: return true
                        default: return false
                        }
                    }.count)
                }
                return .finished(result)
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return .deadline
            }
            defer { group.cancelAll() }

            while let event = try await group.next() {
                switch event {
                case .finished(let result):
                    try Task.checkCancellation()
                    return result
                case .deadline:
                    // If declined or cancelled, structured concurrency cancels
                    // the refresh and waits for the current install to finish.
                    try await requestToContinueInForeground(
                        "SideInstaller needs more time to finish refreshing your apps.")
                }
            }
            throw CancellationError()
        }
        intentProgress.completedUnitCount = intentProgress.totalUnitCount
        return .result(dialog: "\(result.dialog)")
    }
}
