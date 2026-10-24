import Foundation

@main
struct SigningStateTests {
    static func main() {
        let unavailable = EmbeddedSigningCheck.activationIssue("Cannot read certificate", needsProfileUpdate: false)
        precondition(!unavailable.passed && !unavailable.needsRepair)
        let differentLeaf = EmbeddedSigningCheck.activationIssue("Profile needs updating", needsProfileUpdate: true)
        precondition(!differentLeaf.passed && differentLeaf.needsRepair)
        let rejected = EmbeddedSigningCheck.deviceResult(false, error: "F_CHECK_LV failed")
        precondition(!rejected.passed && !rejected.needsRepair)
        precondition(rejected.message.contains("F_CHECK_LV failed"))
        let ready = EmbeddedSigningCheck.deviceResult(true, error: nil)
        precondition(ready.passed && !ready.needsRepair)
        print("Signing states distinguish device success, profile mismatch and test failure")
    }
}
