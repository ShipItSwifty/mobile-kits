import Foundation

/// Errors thrown by the mobile-kits mechanisms. Consumers map these into their own error types
/// at their boundary; the toolkit never decides exit codes or user-facing remediation.
public enum MobileKitError: Error, Equatable, Sendable, LocalizedError {
    /// A tool exited non-zero. `output` is the combined stderr and stdout, trimmed.
    case commandFailed(command: [String], exitCode: Int32, output: String)
    /// A tool or wait did not finish in time.
    case timedOut(operation: String, seconds: Double)
    /// A required executable is not installed or not on `PATH`.
    case toolNotFound(String)
    /// The operation needs a host capability this machine lacks (for example Xcode on Linux).
    case unsupportedHost(String)
    /// A tool's output could not be understood.
    case unexpectedOutput(tool: String, detail: String)
    /// A named resource (device, AVD, runtime, artifact) does not exist.
    case notFound(String)
    /// A device is claimed by someone else.
    case deviceClaimed(device: String, holder: String)
    /// A process the caller started exited before it became ready.
    case processExited(description: String, exitCode: Int32?, logTail: String)
    /// An invariant or input was invalid.
    case invalidRequest(String)
    /// CoreDevice rejected a `devicectl` operation and said why.
    case coreDeviceFailed(CoreDeviceFailure)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let output):
            "`\(command.joined(separator: " "))` exited \(exitCode)\(output.isEmpty ? "" : ": \(output)")"
        case .timedOut(let operation, let seconds):
            "\(operation) did not finish within \(Int(seconds))s"
        case .toolNotFound(let tool):
            "`\(tool)` was not found"
        case .unsupportedHost(let detail):
            detail
        case .unexpectedOutput(let tool, let detail):
            "Could not read \(tool) output: \(detail)"
        case .notFound(let detail):
            detail
        case .deviceClaimed(let device, let holder):
            "Device \(device) is claimed by \(holder)"
        case .processExited(let description, let exitCode, let logTail):
            "\(description) exited\(exitCode.map { " with status \($0)" } ?? "")\(logTail.isEmpty ? "" : ":\n\(logTail)")"
        case .invalidRequest(let detail):
            detail
        case .coreDeviceFailed(let failure):
            [failure.message, failure.reason].compactMap { $0 }.joined(separator: " ")
                + " (\(failure.domain) \(failure.code))"
        }
    }
}
