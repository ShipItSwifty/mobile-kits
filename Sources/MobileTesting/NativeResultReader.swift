import Foundation
import MobileCore
import SwiftyShell

/// The encoding of a native test-result artifact, independent of the platform the tests ran on.
public enum NativeResultFormat: String, Codable, Sendable, CaseIterable {
    /// An Xcode `.xcresult` bundle.
    case xcresult
    /// JUnit XML: a file or a directory of files (Gradle, `swift test --xunit-output`, Bazel).
    case junit
    /// `flutter test --machine` newline-delimited JSON.
    case flutter
    /// Jest `--json` output.
    case jest
    /// `swift test --event-stream-output-path` newline-delimited JSON.
    case swift
}

/// Reads any native result artifact into a ``ParsedTestRun``.
///
/// ```swift
/// let run = try await NativeResultReader(shell: shell).read("app/build/test-results/testDebugUnitTest")
/// ```
public struct NativeResultReader: Sendable {
    public let shell: ShellContext

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    /// - Parameters:
    ///   - format: Detected from `path` when `nil`.
    ///   - runner: Overrides the runner when the artifact cannot say (JUnit XML comes from Gradle,
    ///     `swift test`, and Bazel alike).
    ///   - framework: The app's framework, which a bare result file does not record.
    /// - Throws: When the artifact holds no test outcomes: an empty or unreadable run is never a
    ///   successful zero-test run.
    public func read(
        _ path: String,
        format: NativeResultFormat? = nil,
        runner: TestRunner? = nil,
        framework: AppFramework? = nil
    ) async throws -> ParsedTestRun {
        let kind: NativeResultFormat
        if let format {
            kind = format
        } else if let detected = try Self.detect(path) {
            kind = detected
        } else {
            throw MobileKitError.invalidRequest(
                "Cannot tell the result format of '\(path)'; specify one of xcresult, junit, flutter, jest, swift.")
        }
        let run: ParsedTestRun
        switch kind {
        case .xcresult:
            #if os(macOS)
            run = try await IOSXCResultTestParser(shell: shell).parse(xcresultPath: path)
            #else
            throw MobileKitError.unsupportedHost("Reading .xcresult bundles requires macOS and Xcode.")
            #endif
        case .junit:
            run = try await AndroidJUnitTestParser().parse(
                reportDirectory: path, runner: runner ?? .gradle, framework: framework,
                identityRoot: Self.gradleProjectRoot(containing: path))
        case .flutter:
            run = try await FlutterMachineOutputParser().parse(machineOutput: String(contentsOfFile: path, encoding: .utf8))
        case .jest:
            run = try await JestJSONTestParser().parse(
                jsonFilePath: path, framework: framework, identityRoot: Self.packageRoot(containing: path))
        case .swift:
            run = try SwiftEventParser().parse(path: path)
        }
        guard run.hasResults else {
            throw MobileKitError.invalidRequest(
                "No test results found in '\(path)'" + (run.diagnostics.first.map { ": \($0.message)" } ?? "."))
        }
        return ParsedTestRun(
            runner: runner ?? run.runner, framework: framework ?? run.framework, source: path, destinations: run.destinations,
            summary: run.summary, suites: run.suites, testCases: run.testCases, diagnostics: run.diagnostics)
    }

    /// The format of a native artifact, or `nil` when `path` is not one (for example a consumer's
    /// own report envelope, which the consumer recognizes itself).
    public static func detect(_ path: String) throws -> NativeResultFormat? {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension {
        case "xcresult": return .xcresult
        case "xml": return .junit
        case "jsonl", "ndjson":
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let isSwiftEvents = text.components(separatedBy: .newlines).prefix(10).contains {
                $0.contains("\"payload\"") && $0.contains("\"version\"")
            }
            return isSwiftEvents ? .swift : .flutter
        default: break
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return files.contains { $0.pathExtension == "xml" } ? .junit : nil
        }
        if let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["testResults"] != nil
        {
            return .jest
        }
        return nil
    }

    /// The nearest enclosing JavaScript project (a directory with `package.json`), so offline Jest
    /// identities match those a live run computes relative to the project root.
    public static func packageRoot(containing path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path) { return directory.path }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// The nearest enclosing Gradle project (`settings.gradle[.kts]` or `gradlew`), so offline
    /// identities match those a live run computes relative to the project directory.
    public static func gradleProjectRoot(containing path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
            directory.deleteLastPathComponent()
        }
        while directory.path != "/" {
            for marker in ["settings.gradle.kts", "settings.gradle", "gradlew"]
            where FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) {
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
