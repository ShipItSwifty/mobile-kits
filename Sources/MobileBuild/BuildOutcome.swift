import Foundation
import MobileCore
import SwiftyShell

/// What a build produced.
public struct BuildArtifact: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An `.app` bundle (simulator or device).
        case app
        case ipa
        case xcarchive
        case dsym
        case xctestrun
        case framework
        case xcframework
        case apk
        /// An Android test APK (`androidTest`).
        case testAPK = "test_apk"
        case aab
        /// A JavaScript bundle (React Native `main.jsbundle` / `index.android.bundle`).
        case jsBundle = "js_bundle"
        case executable
        case other
    }

    public var kind: Kind
    public var path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// How build output is handled while a build runs.
public struct BuildOutput: Sendable {
    public var stdout: OutputDestination
    public var stderr: OutputDestination

    public init(stdout: OutputDestination = .capture, stderr: OutputDestination = .capture) {
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Captured and echoed live (`.tee`), for long builds a person is watching.
    public static let streaming = BuildOutput(stdout: .tee, stderr: .tee)
    /// Captured and echoed to stderr, keeping stdout free for machine-readable output.
    public static let streamingToStderr = BuildOutput(stdout: .teeTo(.stderr), stderr: .teeTo(.stderr))
}

/// The result of a build step.
public struct BuildOutcome: Sendable {
    public var backend: BuildBackend
    /// Artifacts the tool reported, in a stable order. Never guessed from conventional paths
    /// when the tool can say; ``diagnostics`` explains any fallback.
    public var artifacts: [BuildArtifact]
    public var warnings: Int
    public var errors: Int
    /// `** BUILD SUCCEEDED **`, `BUILD SUCCESSFUL in 4s`, ….
    public var resultLine: String?
    public var durationSeconds: Double
    public var output: ShellOutput
    public var diagnostics: [String]

    public init(
        backend: BuildBackend,
        artifacts: [BuildArtifact] = [],
        warnings: Int = 0,
        errors: Int = 0,
        resultLine: String? = nil,
        durationSeconds: Double = 0,
        output: ShellOutput,
        diagnostics: [String] = []
    ) {
        self.backend = backend
        self.artifacts = artifacts
        self.warnings = warnings
        self.errors = errors
        self.resultLine = resultLine
        self.durationSeconds = durationSeconds
        self.output = output
        self.diagnostics = diagnostics
    }

    /// The artifacts of one kind.
    public func artifacts(_ kind: BuildArtifact.Kind) -> [String] {
        artifacts.filter { $0.kind == kind }.map(\.path)
    }
}

/// A build that ran and failed. Carries the full log for the caller to report.
public struct BuildFailure: Error, Sendable, LocalizedError {
    public var backend: BuildBackend
    public var command: [String]
    public var exitCode: Int32
    public var output: ShellOutput
    public var summary: String?

    public var errorDescription: String? {
        "\(backend.rawValue) build failed (exit \(exitCode))\(summary.map { ": \($0)" } ?? "")"
    }

    /// stdout then stderr, without empty streams.
    public var log: String {
        [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The result marker and diagnostic counts of an `xcodebuild` log.
public struct XcodeBuildLogSummary: Sendable, Equatable {
    public var resultLine: String?
    public var warningCount: Int
    public var errorCount: Int

    public init(resultLine: String? = nil, warningCount: Int = 0, errorCount: Int = 0) {
        self.resultLine = resultLine
        self.warningCount = warningCount
        self.errorCount = errorCount
    }

    /// Reads `** BUILD SUCCEEDED **`-style markers and clang/swift `file:line:col: warning:` lines.
    public static func parse(_ log: String) -> XcodeBuildLogSummary {
        var summary = XcodeBuildLogSummary()
        for rawLine in log.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if summary.resultLine == nil, line.hasPrefix("**"), line.hasSuffix("**"),
                line.contains("SUCCEEDED") || line.contains("FAILED")
            {
                summary.resultLine = line
            }
            if line.contains(": warning:") { summary.warningCount += 1 }
            if line.contains(": error:") { summary.errorCount += 1 }
        }
        return summary
    }
}

/// The result line, task counts, and build-scan URL of a Gradle log.
public struct GradleLogSummary: Sendable, Equatable {
    public var resultLine: String?
    public var actionableTasksLine: String?
    public var buildScanURL: String?
    public var warningCount: Int

    public init(resultLine: String? = nil, actionableTasksLine: String? = nil, buildScanURL: String? = nil, warningCount: Int = 0) {
        self.resultLine = resultLine
        self.actionableTasksLine = actionableTasksLine
        self.buildScanURL = buildScanURL
        self.warningCount = warningCount
    }

    public static func parse(_ log: String) -> GradleLogSummary {
        var summary = GradleLogSummary()
        for rawLine in log.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if summary.resultLine == nil, line.contains("BUILD SUCCESSFUL") || line.contains("BUILD FAILED") {
                summary.resultLine = line
            }
            if summary.actionableTasksLine == nil, line.contains("actionable task") {
                summary.actionableTasksLine = line
            }
            if summary.buildScanURL == nil {
                summary.buildScanURL = line.split(separator: " ").map(String.init).first {
                    ($0.hasPrefix("https://") || $0.hasPrefix("http://")) && $0.contains("/s/")
                }
            }
            // Kotlin `w: file.kt:…` and javac/AGP `warning:` lines.
            if line.hasPrefix("w: ") || line.contains("warning:") { summary.warningCount += 1 }
        }
        return summary
    }
}

/// Runs a build family, timing it and turning a non-zero exit into a ``BuildFailure``.
func runBuild<Family: RunnableCommandFamily>(
    _ family: Family,
    backend: BuildBackend,
    summarize: (String) -> String? = { _ in nil }
) async throws -> (ShellOutput, Double) {
    let command = family.command()
    let argv = [command.executableName] + command.arguments
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let output = try await command.outputLimit(0).run(in: family.context)
        let elapsed = (clock.now - start).components
        return (output, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    } catch let ShellError.exitFailure(_, output) {
        throw BuildFailure(
            backend: backend, command: argv, exitCode: output.exitCode, output: output,
            summary: summarize(output.stdout + "\n" + output.stderr))
    } catch let error as ShellError {
        throw ToolRunner.map(error, argv: argv)
    }
}
