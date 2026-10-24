#if SIDEINSTALLER_EMBEDDED
import Foundation

struct EmbeddedSigningCheck {
    let passed: Bool
    let needsRepair: Bool
    let message: String

    static func activationIssue(_ message: String, needsProfileUpdate: Bool) -> Self {
        .init(passed: false, needsRepair: needsProfileUpdate, message: message)
    }

    static func deviceResult(_ passed: Bool, error: String?) -> Self {
        .init(passed: passed, needsRepair: false, message: passed
            ? "Ready. The certificate matches this installation and the device signing test passed."
            : "The certificate matches this installation, but the device signing test failed. Updating the certificate again is not a confirmed fix.\n\n" + (error ?? "No error details were returned."))
    }
}
#endif
