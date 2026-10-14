import BazelKit
import FlutterKit
import Foundation
import GradleKit
import Logging
import MobileBuild
import MobileCore
import SwiftPMKit
import SwiftyShell
import XcodeBuildKit

/// The result of running tests once.
///
/// Failing tests are a result, not an error: ``run`` holds them and ``exitCode`` is non-zero.
/// Runners throw only when nothing usable came back (the build failed, the runner crashed, or it
/// exited 0 without reporting a single outcome).
public struct TestExecution: Sendable {
    public enum Status: Sendable, Equatable {
        /// Tests ran and reported outcomes.
        case completed
        /// The tool legitimately had nothing to run (Gradle `NO-SOURCE`); never a pass.
        case notExecuted(reason: String)
    }

    public var run: ParsedTestRun
    public var status: Status
    public var exitCode: Int32
    public var output: ShellOutput
    /// The argv that ran, for evidence.
    public var command: [String]
    /// Result bundles, JUnit directories, and event files the run wrote.
    public var artifacts: [String]
    public var durationSeconds: Double
}

/// Tests ran but reported nothing: a crash, a build failure, or a misconfigured runner.
public struct TestExecutionFailure: Error, Sendable, LocalizedError {
    public var command: [String]
    public var exitCode: Int32
    public var output: ShellOutput
    public var reason: String

    public var errorDescription: String? { "\(reason) (exit \(exitCode))" }

    public var log: String { [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// Runs `family`, returning its output whatever the exit status, with the elapsed time.
func execute<Family: RunnableCommandFamily>(_ family: Family) async throws -> (ShellOutput, [String], Double) {
    let command = family.command().outputLimit(0)
    let argv = [command.executableName] + command.arguments
    let clock = ContinuousClock()
    let start = clock.now
    let output: ShellOutput
    do {
        output = try await command.run(in: family.context)
    } catch let ShellError.exitFailure(_, captured) {
        output = captured
    } catch let error as ShellError {
        throw ToolRunner.map(error, argv: argv)
    }
    let elapsed = (clock.now - start).components
    return (output, argv, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
}

// MARK: - Xcode

/// Which tests an Xcode run includes.
public struct XcodeTestSelection: Sendable, Equatable {
    public var testPlan: String?
    /// `-only-testing:` identifiers such as `AppTests/LoginTests/testValid`.
    public var onlyTesting: [String]
    public var skipTesting: [String]
    public var onlyTestConfigurations: [String]

    public init(testPlan: String? = nil, onlyTesting: [String] = [], skipTesting: [String] = [], onlyTestConfigurations: [String] = []) {
        self.testPlan = testPlan
        self.onlyTesting = onlyTesting
        self.skipTesting = skipTesting
        self.onlyTestConfigurations = onlyTestConfigurations
    }

    var options: [XcodeBuildOption] {
        (testPlan.map { [.testPlan($0)] } ?? []) + onlyTesting.map { .onlyTesting($0) } + skipTesting.map { .skipTesting($0) }
            + onlyTestConfigurations.map { .onlyTestConfiguration($0) }
    }
}

/// Runs XCTest and Swift Testing bundles with `xcodebuild` and reads the result bundle.
public struct XcodeTestRunner: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let logger = Logger.forType(XcodeTestRunner.self)

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// `xcodebuild test`, building first.
    ///
    /// - Parameter resultBundlePath: Must not exist yet; xcodebuild refuses to overwrite one.
    public func test(
        _ request: XcodeBuildRequest, selection: XcodeTestSelection = .init(), resultBundlePath: String
    ) async throws
        -> TestExecution
    {
        var resolved = request
        resolved.resultBundlePath = resultBundlePath
        resolved.additionalOptions += selection.options
        logger.info("xcodebuild test", metadata: ["scheme": "\(request.scheme)", "bundle": "\(resultBundlePath)"])
        return try await run(XcodeBuilder(shell: shell, output: output).command(for: resolved).test(), resultBundlePath: resultBundlePath)
    }

    /// `xcodebuild test-without-building -xctestrun <file>`, reusing a `build-for-testing` product.
    public func testWithoutBuilding(
        xctestrun: String,
        destination: XcodeDestination,
        selection: XcodeTestSelection = .init(),
        resultBundlePath: String,
        additionalOptions: [XcodeBuildOption] = []
    ) async throws -> TestExecution {
        logger.info("xcodebuild test-without-building", metadata: ["xctestrun": "\(xctestrun)", "bundle": "\(resultBundlePath)"])
        return try await testWithoutBuilding(
            input: .xctestrun(xctestrun), destination: destination, selection: selection, resultBundlePath: resultBundlePath,
            additionalOptions: additionalOptions)
    }

    /// `xcodebuild test-without-building -testProductsPath <bundle>`, reusing the `.xctestproducts`
    /// bundle ``XcodeBuilder/buildForTesting(_:testProductsPath:)`` wrote.
    public func testWithoutBuilding(
        testProducts: String,
        destination: XcodeDestination,
        selection: XcodeTestSelection = .init(),
        resultBundlePath: String,
        additionalOptions: [XcodeBuildOption] = []
    ) async throws -> TestExecution {
        logger.info("xcodebuild test-without-building", metadata: ["products": "\(testProducts)", "bundle": "\(resultBundlePath)"])
        return try await testWithoutBuilding(
            input: .testProductsPath(testProducts), destination: destination, selection: selection, resultBundlePath: resultBundlePath,
            additionalOptions: additionalOptions)
    }

    private func testWithoutBuilding(
        input: XcodeBuildOption,
        destination: XcodeDestination,
        selection: XcodeTestSelection,
        resultBundlePath: String,
        additionalOptions: [XcodeBuildOption]
    ) async throws -> TestExecution {
        var xcodebuild = XcodeBuild(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .option(input)
            .option(.destination(destination.specifier))
            .option(.resultBundlePath(resultBundlePath))
        for option in selection.options + additionalOptions { xcodebuild = xcodebuild.option(option) }
        return try await run(xcodebuild.testWithoutBuilding(), resultBundlePath: resultBundlePath)
    }

    private func run(_ family: XcodeBuild, resultBundlePath: String) async throws -> TestExecution {
        let (log, argv, duration) = try await execute(family)
        guard FileManager.default.fileExists(atPath: resultBundlePath) else {
            throw TestExecutionFailure(
                command: argv, exitCode: log.exitCode, output: log,
                reason: XcodeBuildLogSummary.parse(log.stdout).resultLine ?? "xcodebuild wrote no result bundle")
        }
        #if os(macOS)
        // xcresulttool can fail on a bundle xcodebuild has only just finished writing; give it a moment.
        var parsed: ParsedTestRun?
        var readError: Error?
        for attempt in 1...3 {
            do {
                parsed = try await IOSXCResultTestParser(shell: shell).parse(xcresultPath: resultBundlePath)
                break
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                readError = error
                if attempt < 3 { try await Task.sleep(for: .milliseconds(250 * attempt)) }
            }
        }
        guard let parsed else {
            throw TestExecutionFailure(
                command: argv, exitCode: log.exitCode, output: log,
                reason: "Could not read the result bundle: \(readError.map { String(describing: $0) } ?? "unknown error")")
        }
        guard parsed.hasResults else {
            throw TestExecutionFailure(
                command: argv, exitCode: log.exitCode, output: log, reason: "The result bundle holds no test outcomes")
        }
        return TestExecution(
            run: parsed, status: .completed, exitCode: log.exitCode, output: log, command: argv, artifacts: [resultBundlePath],
            durationSeconds: duration)
        #else
        throw MobileKitError.unsupportedHost("Reading .xcresult bundles requires macOS and Xcode.")
        #endif
    }
}

// MARK: - Gradle

/// Where Gradle test tasks write JUnit XML, and how to tell a task that had nothing to run.
public enum GradleTestResults {
    /// `<module>/build/test-results/<task>` for JVM unit tests and
    /// `<module>/build/outputs/androidTest-results/connected` for connected tests. A
    /// module-qualified task (`:app:testDebugUnitTest`) looks in that module only; an
    /// unqualified one in every module.
    public static func reportDirectories(projectDirectory: String, task: String) -> [URL] {
        let parts = task.split(separator: ":").map(String.init)
        guard let taskName = parts.last else { return [] }
        let root = URL(fileURLWithPath: projectDirectory).standardizedFileURL
        let connected = taskName.hasPrefix("connected")
        func results(inBuild build: URL) -> URL? {
            let url =
                connected
                ? build.appendingPathComponent("outputs/androidTest-results/connected", isDirectory: true)
                : build.appendingPathComponent("test-results/\(taskName)", isDirectory: true)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
        if parts.count > 1 {
            let module = root.appendingPathComponent(parts.dropLast().joined(separator: "/"), isDirectory: true)
            return results(inBuild: module.appendingPathComponent("build", isDirectory: true)).map { [$0] } ?? []
        }
        var found: [URL] = []
        let dependencies: Set<String> = ["node_modules", "Pods", "DerivedData", "vendor"]
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        while let url = walker.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if url.lastPathComponent == "build" {
                if let match = results(inBuild: url) { found.append(match) }
                walker.skipDescendants()
            } else if dependencies.contains(url.lastPathComponent) {
                walker.skipDescendants()
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `true` when Gradle reported `NO-SOURCE` or `SKIPPED` for exactly this test task: a
    /// legitimate empty run. Other tasks reporting `NO-SOURCE` say nothing about the tests.
    public static func taskHadNothingToRun(_ log: String, task: String) -> Bool {
        let parts = task.split(separator: ":").map(String.init)
        guard let leaf = parts.last else { return false }
        let name =
            parts.count > 1
            ? ":" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: ":")
            : "(?:\\S*:)?" + NSRegularExpression.escapedPattern(for: leaf)
        return log.range(of: "(?m)^> Task " + name + " (?:NO-SOURCE|SKIPPED)\\s*$", options: .regularExpression) != nil
    }

    /// Every report directory for `task`, merged into one run; `nil` when none exist.
    public static func read(
        projectDirectory: String,
        task: String,
        framework: AppFramework? = nil,
        runner: TestRunner = .gradle
    ) async throws -> ParsedTestRun? {
        let directories = reportDirectories(projectDirectory: projectDirectory, task: task)
        guard !directories.isEmpty else { return nil }
        var runs: [ParsedTestRun] = []
        for directory in directories {
            runs.append(
                try await AndroidJUnitTestParser().parse(
                    reportDirectory: directory.path, runner: runner, framework: framework, identityRoot: projectDirectory))
        }
        let destinations = runs.flatMap(\.destinations).reduce(into: [TestDestination]()) { if !$0.contains($1) { $0.append($1) } }
        return ParsedTestRun(
            runner: runner, framework: framework, source: projectDirectory, destinations: destinations,
            summary: TestSummary(
                passed: runs.reduce(0) { $0 + $1.summary.passed }, failed: runs.reduce(0) { $0 + $1.summary.failed },
                skipped: runs.reduce(0) { $0 + $1.summary.skipped }, errored: runs.reduce(0) { $0 + $1.summary.errored }),
            suites: runs.flatMap(\.suites), testCases: runs.flatMap(\.testCases), diagnostics: runs.flatMap(\.diagnostics))
    }
}

/// Runs Gradle test tasks (JVM unit tests, connected instrumentation, KMP targets) and reads
/// their JUnit XML.
public struct GradleTestRunner: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let logger = Logger.forType(GradleTestRunner.self)

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// Runs one test task.
    ///
    /// - Parameters:
    ///   - filters: `--tests` patterns; task options, so they follow the task. Connected tests
    ///     select with `-Pandroid.testInstrumentationRunnerArguments.class=` instead, through
    ///     `project.properties`.
    ///   - continueAfterFailure: `--continue`, so independent modules finish before failures are read.
    public func run(
        task: GradleTask,
        filters: [String] = [],
        in project: GradleProject,
        framework: AppFramework? = nil,
        continueAfterFailure: Bool = false
    ) async throws -> TestExecution {
        // Results from a previous run must never be read as this run's.
        for directory in GradleTestResults.reportDirectories(projectDirectory: project.directory, task: task.name) {
            try? FileManager.default.removeItem(at: directory)
        }
        logger.info("Gradle test task", metadata: ["task": "\(task.name)", "filters": "\(filters.count)"])
        var gradle = GradleBuilder(shell: shell, output: output).command(for: project).task(
            filters.isEmpty ? task : task.filteringTests(filters))
        if continueAfterFailure { gradle = gradle.flag(.continueAfterFailure) }
        let (log, argv, duration) = try await execute(gradle)
        let artifacts = GradleTestResults.reportDirectories(projectDirectory: project.directory, task: task.name).map(\.path)
        if let run = try await GradleTestResults.read(projectDirectory: project.directory, task: task.name, framework: framework),
            run.hasResults
        {
            return TestExecution(
                run: run, status: .completed, exitCode: log.exitCode, output: log, command: argv, artifacts: artifacts,
                durationSeconds: duration)
        }
        let combined = log.stdout + "\n" + log.stderr
        if log.exitCode == 0, GradleTestResults.taskHadNothingToRun(combined, task: task.name) {
            let empty = ParsedTestRun(
                runner: .gradle, framework: framework, source: "gradle", summary: .init(),
                diagnostics: [.init(severity: .info, message: "Gradle reported NO-SOURCE/SKIPPED: the test task had no tests to run")])
            return TestExecution(
                run: empty, status: .notExecuted(reason: "\(task.name) had no tests to run"), exitCode: 0, output: log,
                command: argv, artifacts: [], durationSeconds: duration)
        }
        throw TestExecutionFailure(
            command: argv, exitCode: log.exitCode, output: log,
            reason: log.exitCode == 0
                ? "Gradle task '\(task.name)' exited 0 but wrote no JUnit XML"
                : GradleLogSummary.parse(combined).resultLine ?? "Gradle task '\(task.name)' failed before reporting tests")
    }
}

// MARK: - SwiftPM

/// Runs `swift test` and reads its event stream.
public struct SwiftPMTestRunner: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// - Parameter outputDirectory: Receives `events.jsonl`, `xctest.xml`, and attachments.
    public func run(
        packagePath: String,
        outputDirectory: String,
        scratchPath: String? = nil,
        filter: String? = nil,
        skip: String? = nil,
        coverage: Bool = false,
        skipBuild: Bool = false,
        workers: Int? = nil,
        environment: [String: String] = [:]
    ) async throws -> TestExecution {
        let directory = URL(fileURLWithPath: outputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = directory.appendingPathComponent("events.jsonl").path
        try? FileManager.default.removeItem(atPath: events)
        let family = SwiftPM(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .test(
                packagePath: packagePath, scratchPath: scratchPath, eventStream: events,
                attachments: directory.appendingPathComponent("attachments").path, coverage: coverage, skipBuild: skipBuild,
                filter: filter, skip: skip, xunit: directory.appendingPathComponent("xctest.xml").path, workers: workers
            )
            .env(environment)
        let (log, argv, duration) = try await execute(family)
        guard FileManager.default.fileExists(atPath: events), let run = try? SwiftEventParser().parse(path: events), run.hasResults else {
            throw TestExecutionFailure(command: argv, exitCode: log.exitCode, output: log, reason: "swift test reported no test outcomes")
        }
        return TestExecution(
            run: run, status: .completed, exitCode: log.exitCode, output: log, command: argv, artifacts: [events],
            durationSeconds: duration)
    }
}

// MARK: - Flutter

/// Runs `flutter test` (unit and widget tests on the host) and `integration_test` on a device.
public struct FlutterTestRunner: Sendable {
    private let shell: ShellContext
    private let executable: (path: String, prefix: [String])

    public init(shell: ShellContext = .init(), executable: (path: String, prefix: [String]) = ("flutter", [])) {
        self.shell = shell
        self.executable = executable
    }

    private func flutter(_ directory: String) -> Flutter {
        Flutter(context: shell, executablePath: executable.path, prefix: executable.prefix).workingDirectory(directory)
    }

    /// Unit and widget tests, `--machine` output parsed.
    public func runUnitTests(in directory: String, name: String? = nil, coverage: Bool = false) async throws -> TestExecution {
        try await parse(flutter(directory).testMachine(coverage: coverage, name: name), destination: TestDestination.host())
    }

    /// `integration_test` on a device or simulator.
    public func runIntegrationTests(
        in directory: String,
        device: String,
        platform: TestPlatform,
        paths: [String] = ["integration_test"],
        name: String? = nil
    ) async throws -> TestExecution {
        try await parse(
            flutter(directory).integrationTest(device: device, paths: paths, machine: true, name: name),
            destination: TestDestination(platform: platform, name: device))
    }

    private func parse(_ family: Flutter, destination: TestDestination) async throws -> TestExecution {
        let (log, argv, duration) = try await execute(family)
        let parsed = try await FlutterMachineOutputParser().parse(machineOutput: log.stdout)
        guard parsed.hasResults else {
            throw TestExecutionFailure(command: argv, exitCode: log.exitCode, output: log, reason: "flutter test reported no test outcomes")
        }
        let run = ParsedTestRun(
            runner: parsed.runner, framework: .flutter, source: parsed.source,
            destinations: parsed.destinations.isEmpty ? [destination] : parsed.destinations, summary: parsed.summary,
            suites: parsed.suites,
            testCases: parsed.testCases.map { $0.destinationID == nil ? $0.copy(destinationID: .some(destination.id)) : $0 },
            diagnostics: parsed.diagnostics)
        return TestExecution(
            run: run, status: .completed, exitCode: log.exitCode, output: log, command: argv, artifacts: [], durationSeconds: duration)
    }
}

// MARK: - Jest

/// Runs a JavaScript project's test script, reading Jest's JSON report when the script is Jest.
public struct JestTestRunner: Sendable {
    private let shell: ShellContext

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    /// Runs `package.json`'s `script` (default `test`) with `--json --outputFile`.
    ///
    /// - Parameters:
    ///   - selection: Test files and an exact full-name pattern, for targeted reruns.
    public func run(
        project: JavaScriptProject,
        script: String = "test",
        selection: (files: [String], namePattern: String)? = nil,
        framework: AppFramework? = .reactNative
    ) async throws -> TestExecution {
        guard project.scriptUsesJest(script) else {
            throw MobileKitError.invalidRequest("The '\(script)' script does not run Jest, so its results cannot be read")
        }
        let report = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: report) }
        var arguments = ["--json", "--outputFile", report.path]
        if let selection {
            arguments += ["--runTestsByPath"] + selection.files.sorted() + ["--testNamePattern", selection.namePattern]
        }
        let clock = ContinuousClock()
        let start = clock.now
        let log = try await project.run(script: script, arguments: arguments)
        let elapsed = (clock.now - start).components
        let argv = [project.packageManager.rawValue, "run", script, "--"] + arguments
        guard FileManager.default.fileExists(atPath: report.path),
            let run = try? await JestJSONTestParser().parse(jsonFilePath: report.path, framework: framework, identityRoot: project.root),
            run.hasResults
        else {
            throw TestExecutionFailure(command: argv, exitCode: log.exitCode, output: log, reason: "Jest wrote no test results")
        }
        return TestExecution(
            run: run, status: .completed, exitCode: log.exitCode, output: log, command: argv, artifacts: [],
            durationSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}

// MARK: - Bazel

/// Runs `bazel test` and reads every test action's JUnit XML from the build event stream.
public struct BazelTestRunner: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let executablePath: String

    public init(shell: ShellContext = .init(), output: BuildOutput = .init(), executablePath: String = "bazel") {
        self.shell = shell
        self.output = output
        self.executablePath = executablePath
    }

    /// - Parameter testFilter: `--test_filter`, passed to each test runner.
    public func run(
        _ targets: [String], in workspace: String, options: [BazelOption] = [], testFilter: String? = nil
    ) async throws
        -> TestExecution
    {
        let events = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: events) }
        let family = Bazel(context: shell, executablePath: executablePath)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .test(targets)
            .options(options + [.buildEventJSONFile(events.path)] + (testFilter.map { [.testFilter($0)] } ?? []))
            .workingDirectory(workspace)
        let (log, argv, duration) = try await execute(family)
        let stream = BuildEventStream.parse((try? String(contentsOf: events, encoding: .utf8)) ?? "")
        // The last attempt of each test decides its outcome; earlier attempts are retries.
        let finalAttempts = Dictionary(grouping: stream.tests, by: { "\($0.label)#\($0.run)#\($0.shard)" })
            .compactMap { $0.value.max { $0.attempt < $1.attempt } }
            .sorted { $0.label < $1.label }
        var runs: [ParsedTestRun] = []
        for test in finalAttempts {
            for file in test.junitFiles where FileManager.default.fileExists(atPath: file) {
                let parsed = try await AndroidJUnitTestParser().parse(reportDirectory: file, runner: .other("bazel"))
                runs.append(parsed)
            }
        }
        guard !runs.isEmpty else {
            throw TestExecutionFailure(
                command: argv, exitCode: log.exitCode, output: log, reason: "bazel test reported no JUnit results in its build events")
        }
        let merged = ParsedTestRun.merging(runs, source: workspace)
        return TestExecution(
            run: merged, status: .completed, exitCode: log.exitCode, output: log, command: argv,
            artifacts: finalAttempts.flatMap(\.junitFiles), durationSeconds: duration)
    }
}
