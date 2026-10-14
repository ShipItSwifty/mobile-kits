import BazelKit
import CodesignKit
import Foundation
import Logging
import MobileCore
import SwiftPMKit
import SwiftyShell
import TuistCLIKit
import XcodeGenKit

// MARK: - Bazel

/// The parts of Bazel's Build Event Protocol (`--build_event_json_file`) that report outputs
/// and test results.
public struct BuildEventStream: Sendable, Equatable {
    public struct TargetOutputs: Sendable, Equatable {
        public var label: String
        public var success: Bool
        public var files: [String]
    }

    public struct TestResult: Sendable, Equatable {
        public var label: String
        public var run: Int
        public var shard: Int
        public var attempt: Int
        /// `PASSED`, `FAILED`, `FLAKY`, `TIMEOUT`, `NO_STATUS`, ….
        public var status: String
        /// Paths of `test.xml` (JUnit) files the test action wrote.
        public var junitFiles: [String]
        public var logFiles: [String]
        public var durationMillis: Int?
    }

    public var targets: [TargetOutputs]
    public var tests: [TestResult]

    /// Parses newline-delimited BEP JSON.
    public static func parse(_ text: String) -> BuildEventStream {
        var namedSets: [String: (files: [String], children: [String])] = [:]
        var completions: [(label: String, success: Bool, sets: [String])] = []
        var tests: [TestResult] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let id = event["id"] as? [String: Any]
            else { continue }
            if let set = event["namedSetOfFiles"] as? [String: Any], let named = id["namedSet"] as? [String: Any],
                let setID = named["id"] as? String
            {
                let files = (set["files"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }.compactMap(Self.path)
                let children = (set["fileSets"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                namedSets[setID] = (files, children)
            }
            if let completed = event["completed"] as? [String: Any], let target = id["targetCompleted"] as? [String: Any],
                let label = target["label"] as? String
            {
                let groups = completed["outputGroup"] as? [[String: Any]] ?? []
                let sets = groups.filter { ($0["name"] as? String) == "default" }
                    .flatMap { ($0["fileSets"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
                completions.append((label, completed["success"] as? Bool ?? false, sets))
            }
            if let result = event["testResult"] as? [String: Any], let testID = id["testResult"] as? [String: Any],
                let label = testID["label"] as? String
            {
                let outputs = (result["testActionOutput"] as? [[String: Any]] ?? []).compactMap { output -> (String, String)? in
                    guard let name = output["name"] as? String, let uri = output["uri"] as? String, let path = Self.path(uri) else {
                        return nil
                    }
                    return (name, path)
                }
                tests.append(
                    TestResult(
                        label: label, run: testID["run"] as? Int ?? 1, shard: testID["shard"] as? Int ?? 1,
                        attempt: testID["attempt"] as? Int ?? 1, status: result["status"] as? String ?? "NO_STATUS",
                        junitFiles: outputs.filter { $0.0 == "test.xml" }.map(\.1),
                        logFiles: outputs.filter { $0.0 == "test.log" }.map(\.1),
                        durationMillis: (result["testAttemptDurationMillis"] as? String).flatMap(Int.init)
                            ?? result["testAttemptDurationMillis"] as? Int))
            }
        }
        func files(_ setID: String, seen: inout Set<String>) -> [String] {
            guard seen.insert(setID).inserted, let set = namedSets[setID] else { return [] }
            return set.files + set.children.flatMap { files($0, seen: &seen) }
        }
        let targets = completions.map { completion -> TargetOutputs in
            var seen: Set<String> = []
            return TargetOutputs(
                label: completion.label, success: completion.success, files: completion.sets.flatMap { files($0, seen: &seen) })
        }
        return BuildEventStream(targets: targets, tests: tests)
    }

    static func path(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        return URL(string: uri)?.path
    }
}

/// Builds Bazel targets, reporting outputs from the Build Event Protocol.
public struct BazelBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let executablePath: String
    private let logger = Logger.forType(BazelBuilder.self)

    /// - Parameter executablePath: `bazel`, `bazelisk`, or a workspace wrapper such as `./tools/bazel`.
    public init(shell: ShellContext = .init(), output: BuildOutput = .init(), executablePath: String = "bazel") {
        self.shell = shell
        self.output = output
        self.executablePath = executablePath
    }

    /// `bazel build <targets>` with a build-event file, returning every default output.
    public func build(_ targets: [String], in workspace: String, options: [BazelOption] = []) async throws -> BuildOutcome {
        let events = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: events) }
        logger.info("bazel build", metadata: ["targets": "\(targets)"])
        let family = Bazel(context: shell, executablePath: executablePath)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .build(targets)
            .options(options + [.buildEventJSONFile(events.path)])
            .workingDirectory(workspace)
        let (log, duration) = try await runBuild(family, backend: .bazel)
        let stream = BuildEventStream.parse((try? String(contentsOf: events, encoding: .utf8)) ?? "")
        let artifacts = stream.targets.flatMap(\.files).map { BuildArtifact(kind: artifactKind(for: $0) ?? .other, path: $0) }
        return BuildOutcome(
            backend: .bazel, artifacts: artifacts, durationSeconds: duration, output: log,
            diagnostics: stream.targets.filter { !$0.success }.map { "\($0.label) failed" })
    }
}

// MARK: - SwiftPM

/// Builds Swift packages.
public struct SwiftPMBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// `swift build`, reporting the product executable when `product` names one.
    public func build(
        packagePath: String,
        product: String? = nil,
        configuration: SwiftPMConfiguration = .debug,
        scratchPath: String? = nil
    ) async throws -> BuildOutcome {
        let family = SwiftPM(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .build(packagePath: packagePath, product: product, configuration: configuration, scratchPath: scratchPath)
        let (log, duration) = try await runBuild(family, backend: .swiftPM)
        var artifacts: [BuildArtifact] = []
        if let product {
            let binPath = try await ToolRunner.run(
                SwiftPM(context: shell).build(packagePath: packagePath, configuration: configuration, scratchPath: scratchPath)
                    .command().args(["--show-bin-path"]), context: shell)
            let executable = (binPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).appendingPathComponent(product)
            if FileManager.default.isExecutableFile(atPath: executable) {
                artifacts.append(BuildArtifact(kind: .executable, path: executable))
            }
        }
        return BuildOutcome(backend: .swiftPM, artifacts: artifacts, durationSeconds: duration, output: log)
    }
}

// MARK: - Project generation

/// Generates Xcode projects from XcodeGen or Tuist manifests.
///
/// Generation runs repository code (Tuist manifests are Swift); it is an explicit step, never
/// part of inspection.
public struct ProjectGenerator: Sendable {
    public enum Tool: Sendable, Equatable {
        /// `xcodegen generate --spec <spec>`.
        case xcodeGen(spec: String?)
        /// `tuist install` then `tuist generate --no-open`.
        case tuist
    }

    private let shell: ShellContext
    private let logger = Logger.forType(ProjectGenerator.self)

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    public func generate(_ tool: Tool, in directory: String) async throws {
        logger.info("Generating Xcode project", metadata: ["tool": "\(tool)", "directory": "\(directory)"])
        switch tool {
        case .xcodeGen(let spec):
            var xcodegen = XcodeGen(context: shell).generate()
            if let spec { xcodegen = xcodegen.option(.spec(spec)) }
            try await ToolRunner.run(xcodegen.workingDirectory(directory), timeout: .seconds(300))
        case .tuist:
            try await ToolRunner.run(Tuist(context: shell).install().path(directory), timeout: .seconds(900))
            try await ToolRunner.run(Tuist(context: shell).generate(open: false).path(directory), timeout: .seconds(600))
        }
    }
}

// MARK: - Signing

/// Verifies and inspects code signatures.
public struct SigningInspector: Sendable {
    private let shell: ShellContext

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    /// Whether `path` has a valid signature (`codesign --verify --deep --strict`).
    public func verify(_ path: String) async throws -> (valid: Bool, detail: String) {
        let output = try await ToolRunner.capture(Codesign(context: shell).verify(path, deep: true, strict: true), timeout: .seconds(120))
        return (output.exitCode == 0, (output.stderr + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The embedded entitlements.
    public func entitlements(of path: String) async throws -> [String: Any] {
        let output = try await ToolRunner.run(Codesign(context: shell).entitlements(path), timeout: .seconds(60))
        guard !output.stdout.isEmpty else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil)
        return plist as? [String: Any] ?? [:]
    }

    /// `TeamIdentifier=` and `Authority=` lines from `codesign --display --verbose=4` (written to stderr).
    public func signingIdentity(of path: String) async throws -> (teamID: String?, authorities: [String]) {
        let output = try await ToolRunner.run(Codesign(context: shell).display(path), timeout: .seconds(60))
        let lines = (output.stderr + "\n" + output.stdout).split(whereSeparator: \.isNewline).map(String.init)
        let team = lines.first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return (
            team == "not set" ? nil : team, lines.filter { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }
        )
    }
}
