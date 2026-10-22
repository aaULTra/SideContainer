"""Exercise the production JavaScript callback bridge under Release optimization.

The transport methods are replaced with deterministic fakes; no device/debugger
or pairing material is involved. This verifies callback lifetime and exception
propagation, not executable-memory preparation on iOS.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def check(vendor):
    source = (vendor / "Sources/ScriptRunner.swift").read_text()
    source = source.replace("@_implementationOnly import idevice", "")
    # Keep the exact run() implementation, including all weak JS callbacks.
    source = source.split("    private func sendCommand(", 1)[0]
    source += """
    private func sendCommand(_ command: String) -> String? { "ack:" + command }
    private func prepareMemoryRegion(_ address: UInt64, length: UInt64) -> String? { "prepared" }
    private func recordExecutionError(_ error: StikJITError) { executionError = error }
}
"""
    owner = (vendor / "Sources/JITSession.swift").read_text()
    owner = owner.split("        case (true, _), (false, .present):\n", 1)[1].split("        case (false, .absent):", 1)[0]
    harness = '''
enum StikJIT { enum Script { case customBase64(String) ; var name: String { "test" } } }
enum StikJITError: Error { case scriptUnavailable, scriptExecution(String) }
enum BundledScript {
    static func source(for script: StikJIT.Script) throws -> String {
        switch script { case .customBase64(let data): return String(data: Data(base64Encoded: data)!, encoding: .utf8)! }
    }
}
func evaluate(_ text: String, progress: @escaping (String) -> Void) throws {
    let targetPID: Int32 = 4242
    let debugProxy = OpaquePointer(bitPattern: 1)!
    let script = StikJIT.Script.customBase64(Data(text.utf8).base64EncodedString())
OWNER
}
var messages: [String] = []
try evaluate("""
if (get_pid() !== 4242) throw new Error('wrong PID');
if (send_command('probe') !== 'ack:probe') throw new Error('dead send callback');
if (prepare_memory_region(16384,16384) !== 'prepared') throw new Error('dead prepare callback');
log('callbacks worked');
""") { messages.append($0) }
precondition(messages.contains("callbacks worked"), "dead log callback")
do {
    try evaluate("throw new Error('expected script failure')") { _ in }
    fatalError("JavaScript exception was incorrectly reported as success")
} catch StikJITError.scriptExecution(let message) {
    precondition(message.contains("expected script failure"))
}
print("Optimized production script callback and exception checks passed")
'''.replace("OWNER", owner)
    with tempfile.TemporaryDirectory(prefix="si-jit-check-") as temp:
        path = Path(temp) / "ScriptRunnerCheck.swift"
        path.write_text(source + harness)
        binary = Path(temp) / "check"
        subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-framework", "JavaScriptCore", str(path), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vendor", type=Path)
    check(parser.parse_args().vendor)
