import Foundation

@main
struct PreparationTests {
    static func main() {
        let reset = "Socket(Os { code: 54, kind: ConnectionReset, message: Connection reset by peer })"
        precondition(SIJITPreparationStage.reachability.shouldRetry(reason: reset, attempt: 0))
        precondition(SIJITPreparationStage.checkingDDI.shouldRetry(reason: reset, attempt: 0))
        for stage in [SIJITPreparationStage.reachability, .checkingDDI, .downloading, .mounting, .verifying, .ready] {
            precondition(!stage.shouldRetry(reason: reset, attempt: 1), "Retry must be bounded")
            precondition(!stage.shouldRetry(reason: "Pairing verification failed", attempt: 0))
        }
        for stage in [SIJITPreparationStage.downloading, .mounting, .verifying, .ready] {
            precondition(!stage.shouldRetry(reason: reset, attempt: 0), "Do not retry after preflight")
        }
        print("JIT read-only connection-reset retry policy checks passed")
    }
}
