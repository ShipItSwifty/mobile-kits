import Foundation
import Logging
import SwiftyShell

extension Logger {
    /// A logger labelled `"MobileKits.<TypeName>"`. `package` so it never collides with a
    /// consumer's own `forType` helper.
    package static func forType<T>(_ type: T.Type) -> Logger {
        Logger(label: "MobileKits.\(String(describing: T.self))")
    }
}

/// Runs command families and turns SwiftyShell failures into ``MobileKitError``s that carry the
/// argv and output, so callers can report what failed without re-deriving the command.
public enum ToolRunner {
    /// Runs `family`, returning its output when it exits zero.
    ///
    /// - Parameter timeout: Overrides any configured timeout for this one run.
    @discardableResult
    public static func run<Family: RunnableCommandFamily>(
        _ family: Family,
        timeout: Duration? = nil
    ) async throws -> ShellOutput {
        var command = family.command()
        if let timeout { command = command.timeout(timeout) }
        return try await run(command, context: family.context)
    }

    /// Runs a raw command in `context`.
    @discardableResult
    public static func run(_ command: Command, context: ShellContext) async throws -> ShellOutput {
        do {
            return try await command.run(in: context)
        } catch let error as ShellError {
            throw map(error, argv: [command.executableName] + command.arguments)
        }
    }

    /// Runs `family`, returning its output whatever the exit status. Timeouts, launch failures,
    /// and cancellation still throw.
    public static func capture<Family: RunnableCommandFamily>(
        _ family: Family,
        timeout: Duration? = nil
    ) async throws -> ShellOutput {
        var command = family.command()
        if let timeout { command = command.timeout(timeout) }
        do {
            return try await command.run(in: family.context)
        } catch let ShellError.exitFailure(_, output) {
            return output
        } catch let error as ShellError {
            throw map(error, argv: [command.executableName] + command.arguments)
        }
    }

    /// Maps a SwiftyShell error to a ``MobileKitError``.
    public static func map(_ error: ShellError, argv: [String]) -> Error {
        switch error {
        case .exitFailure(_, let output):
            let text = [output.stderr, output.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return MobileKitError.commandFailed(command: argv, exitCode: output.exitCode, output: text)
        case .timeout(_, let duration, _):
            let components = duration.components
            return MobileKitError.timedOut(
                operation: "`\(argv.joined(separator: " "))`",
                seconds: Double(components.seconds) + Double(components.attoseconds) / 1e18
            )
        case .commandNotFound(let tool):
            return MobileKitError.toolNotFound(tool)
        default:
            return error
        }
    }
}
