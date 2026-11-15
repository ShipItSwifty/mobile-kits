import Foundation
import GradleKit
import MobileBuild
import MobileCore
import SwiftyShell
import Synchronization
import TestCommons
import Testing

@testable import MobileTesting

@Suite("Test runners")
struct TestRunnerTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/real")

    static let junit = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="com.example.LoginTest" tests="2" skipped="0" failures="1" errors="0" time="0.2">
          <testcase name="valid" classname="com.example.LoginTest" time="0.1"/>
          <testcase name="invalid" classname="com.example.LoginTest" time="0.1"><failure message="expected">trace</failure></testcase>
        </testsuite>
        """

    @Test("test-without-building reuses an .xctestproducts bundle and reports a missing result bundle with the argv")
    func xcodeTestProducts() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "", stderr: "Failed to clone device", exitCode: 65) }
        let runner = XcodeTestRunner(shell: ShellContext(executor: executor))
        do {
            _ = try await runner.testWithoutBuilding(
                testProducts: "/tmp/App.xctestproducts", destination: .simulator(udid: "UDID"),
                selection: XcodeTestSelection(testPlan: "Unit"), resultBundlePath: scratch.url.appendingPathComponent("r.xcresult").path)
            Issue.record("A run with no result bundle is a failure")
        } catch let failure as TestExecutionFailure {
            #expect(failure.exitCode == 65)
            #expect(failure.output.stderr.contains("Failed to clone"))
            let pairs = Array(zip(failure.command, failure.command.dropFirst()))
            #expect(pairs.contains { $0 == "-testProductsPath" && $1 == "/tmp/App.xctestproducts" })
            #expect(failure.command.contains("test-without-building"))
            #expect(failure.command.contains("Unit"))
        }
    }

    @Test("test-without-building passes every destination and the typed parallel-testing options")
    func xcodeMultipleDestinationsAndParallel() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let seen = Mutex<[String]>([])
        let executor = MockExecutor { command, _ in
            seen.withLock { $0 = command.arguments }
            return ShellOutput(stdout: "", stderr: "", exitCode: 65)
        }
        let runner = XcodeTestRunner(shell: ShellContext(executor: executor))
        do {
            _ = try await runner.testWithoutBuilding(
                xctestrun: "/tmp/App.xctestrun", destinations: [.simulator(udid: "ONE"), .simulator(udid: "TWO")],
                parallel: XcodeParallelTesting(enabled: true, workerCount: 3, maximumWorkers: 5),
                resultBundlePath: scratch.url.appendingPathComponent("r.xcresult").path)
            Issue.record("A run with no result bundle is a failure")
        } catch is TestExecutionFailure {}
        let arguments = seen.withLock { $0 }
        let pairs = Array(zip(arguments, arguments.dropFirst()))
        let destinations = pairs.filter { $0.0 == "-destination" }.map(\.1)
        #expect(destinations == ["platform=iOS Simulator,id=ONE", "platform=iOS Simulator,id=TWO"])
        #expect(pairs.contains { $0 == "-parallel-testing-enabled" && $1 == "YES" })
        #expect(pairs.contains { $0 == "-parallel-testing-worker-count" && $1 == "3" })
        #expect(pairs.contains { $0 == "-maximum-parallel-testing-workers" && $1 == "5" })
    }

    @Test("test-without-building refuses an empty destination list")
    func xcodeNoDestinations() async throws {
        let runner = XcodeTestRunner(shell: ShellContext(executor: MockExecutor { _, _ in ShellOutput(stdout: "", exitCode: 0) }))
        await #expect(throws: MobileKitError.self) {
            _ = try await runner.testWithoutBuilding(
                xctestrun: "/tmp/App.xctestrun", destinations: [], resultBundlePath: "/tmp/never.xcresult")
        }
    }

    @Test("A runner timeout reaches the command and an exceeded one is a timedOut error")
    func runnerTimeouts() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let applied = Mutex<Duration?>(nil)
        let executor = MockExecutor { command, _ in
            applied.withLock { $0 = command.timeoutOverride }
            return ShellOutput(stdout: "BUILD FAILED\n", exitCode: 1)
        }
        let runner = GradleTestRunner(shell: ShellContext(executor: executor), timeout: .seconds(90))
        _ = try? await runner.run(task: GradleTask.custom(":app:test"), in: GradleProject(directory: scratch.url.path))
        #expect(applied.withLock { $0 } == .seconds(90))

        let hung = MockExecutor { command, _ in
            throw ShellError.timeout(
                command: CommandSnapshot(command), duration: .seconds(90), partialOutput: ShellOutput(stdout: "", exitCode: 0))
        }
        do {
            _ = try await GradleTestRunner(shell: ShellContext(executor: hung), timeout: .seconds(90))
                .run(task: GradleTask.custom(":app:test"), in: GradleProject(directory: scratch.url.path))
            Issue.record("A hung command must not look like a finished run")
        } catch MobileKitError.timedOut(_, let seconds) {
            #expect(seconds == 90)
        }
    }

    @Test("Gradle results come from the task's JUnit XML; failures are a result, not an error")
    func gradleReadsJUnit() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let project = scratch.url.path
        let executor = MockExecutor { command, _ in
            #expect(command.arguments.suffix(3) == [":app:testDebugUnitTest", "--tests", "com.example.LoginTest"])
            let reports = URL(fileURLWithPath: project).appending(path: "app/build/test-results/testDebugUnitTest")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try Data(Self.junit.utf8).write(to: reports.appending(path: "TEST-com.example.LoginTest.xml"))
            return ShellOutput(stdout: "BUILD FAILED in 4s\n", exitCode: 1)
        }
        let execution = try await GradleTestRunner(shell: ShellContext(executor: executor)).run(
            task: GradleTask.unitTest(variant: "debug").qualified(module: "app"), filters: ["com.example.LoginTest"],
            in: GradleProject(directory: project))
        #expect(execution.status == .completed)
        #expect(execution.exitCode == 1)
        #expect(execution.run.summary.passed == 1)
        #expect(execution.run.summary.failed == 1)
        #expect(execution.artifacts.count == 1)
    }

    @Test("Merged Gradle report directories sum flaky tests with the other counts")
    func gradleMergedFlakyCount() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let flaky = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="com.example.FlakyTest" tests="2" skipped="0" failures="1" errors="0" time="0.2">
              <testcase name="sometimes" classname="com.example.FlakyTest" time="0.1"><failure message="boom">trace</failure></testcase>
              <testcase name="sometimes" classname="com.example.FlakyTest" time="0.1"/>
            </testsuite>
            """
        for module in ["app", "lib"] {
            let reports = scratch.url.appending(path: "\(module)/build/test-results/test")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try Data(flaky.utf8).write(to: reports.appending(path: "TEST-com.example.FlakyTest.xml"))
        }
        let run = try #require(await GradleTestResults.read(projectDirectory: scratch.url.path, task: "test"))
        #expect(run.summary.flaky == 2)
        #expect(run.summary.passed == 2)
    }

    @Test("NO-SOURCE for the test task is a not-executed run, never a pass")
    func gradleNoSource() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let executor = MockExecutor { _, _ in
            ShellOutput(stdout: "> Task :app:testDebugUnitTest NO-SOURCE\nBUILD SUCCESSFUL\n", exitCode: 0)
        }
        let execution = try await GradleTestRunner(shell: ShellContext(executor: executor)).run(
            task: GradleTask.custom(":app:testDebugUnitTest"), in: GradleProject(directory: scratch.url.path))
        #expect(execution.status == .notExecuted(reason: ":app:testDebugUnitTest had no tests to run"))
        #expect(!execution.run.hasResults)
    }

    @Test("Exiting 0 without results, and failing before any test, are errors")
    func gradleNoResults() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for (stdout, code) in [
            ("BUILD SUCCESSFUL\n", Int32(0)), ("> Task :app:compileDebugUnitTestKotlin FAILED\nBUILD FAILED in 2s\n", 1),
        ] {
            let executor = MockExecutor { _, _ in ShellOutput(stdout: stdout, exitCode: code) }
            await #expect(throws: TestExecutionFailure.self) {
                try await GradleTestRunner(shell: ShellContext(executor: executor)).run(
                    task: GradleTask.custom(":app:testDebugUnitTest"), in: GradleProject(directory: scratch.url.path))
            }
        }
    }

    @Test("Stale JUnit XML from a previous run is removed before the task runs")
    func gradleRemovesStaleResults() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let reports = scratch.url.appending(path: "app/build/test-results/testDebugUnitTest")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try Data(Self.junit.utf8).write(to: reports.appending(path: "TEST-stale.xml"))
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "BUILD SUCCESSFUL\n", exitCode: 0) }
        await #expect(throws: TestExecutionFailure.self) {
            try await GradleTestRunner(shell: ShellContext(executor: executor)).run(
                task: GradleTask.custom(":app:testDebugUnitTest"), in: GradleProject(directory: scratch.url.path))
        }
    }

    @Test("NO-SOURCE matching is specific to the test task")
    func nothingToRunMatching() {
        #expect(GradleTestResults.taskHadNothingToRun("> Task :app:testDebugUnitTest NO-SOURCE", task: ":app:testDebugUnitTest"))
        #expect(GradleTestResults.taskHadNothingToRun("> Task :lib:test SKIPPED", task: "test"))
        #expect(!GradleTestResults.taskHadNothingToRun("> Task :app:compileDebugAidl NO-SOURCE", task: ":app:testDebugUnitTest"))
        #expect(!GradleTestResults.taskHadNothingToRun("> Task :other:testDebugUnitTest NO-SOURCE", task: ":app:testDebugUnitTest"))
    }

    @Test("Swift package tests are read from the event stream")
    func swiftPM() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let events = try Data(contentsOf: Self.fixtures.appending(path: "swift-testing-events/nested-suites.jsonl"))
        let executor = MockExecutor { command, _ in
            let index = try #require(command.arguments.firstIndex(of: "--event-stream-output-path"))
            try events.write(to: URL(fileURLWithPath: command.arguments[index + 1]))
            return ShellOutput(exitCode: 1)
        }
        let execution = try await SwiftPMTestRunner(shell: ShellContext(executor: executor))
            .run(packagePath: ".", outputDirectory: scratch.url.appending(path: "out").path)
        #expect(execution.run.runner == .swiftTest)
        #expect(execution.run.summary.failed > 0)
        #expect(execution.exitCode == 1)
    }

    @Test("Bazel test results come from each test action's final attempt")
    func bazel() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let xml = scratch.url.appending(path: "test.xml")
        let stale = scratch.url.appending(path: "attempt1.xml")
        try Data(Self.junit.utf8).write(to: xml)
        try Data("<testsuite name=\"x\" tests=\"1\"><testcase name=\"only-first-attempt\" classname=\"X\"/></testsuite>".utf8).write(
            to: stale)
        let executor = MockExecutor { command, _ in
            let flag = try #require(command.arguments.first { $0.hasPrefix("--build_event_json_file=") })
            let events = """
                {"id": {"testResult": {"label": "//app:tests", "run": 1, "shard": 1, "attempt": 1}}, "testResult": {"status": "FAILED", "testActionOutput": [{"name": "test.xml", "uri": "file://\(stale.path)"}]}}
                {"id": {"testResult": {"label": "//app:tests", "run": 1, "shard": 1, "attempt": 2}}, "testResult": {"status": "FAILED", "testActionOutput": [{"name": "test.xml", "uri": "file://\(xml.path)"}]}}
                """
            try Data(events.utf8).write(to: URL(fileURLWithPath: String(flag.dropFirst("--build_event_json_file=".count))))
            return ShellOutput(exitCode: 3)
        }
        let execution = try await BazelTestRunner(shell: ShellContext(executor: executor)).run(["//app:tests"], in: scratch.url.path)
        #expect(execution.run.testCases.map(\.name).sorted() == ["invalid", "valid"])
        #expect(execution.artifacts == [xml.path])
        #expect(execution.exitCode == 3)
    }

    @Test("Jest and Flutter runners pass the caller's output destinations to the command")
    func streamingDestinations() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try Data(#"{"scripts": {"test": "jest"}}"#.utf8).write(to: scratch.url.appending(path: "package.json"))
        try FileManager.default.createDirectory(at: scratch.url.appending(path: "node_modules"), withIntermediateDirectories: true)
        let seen = Mutex<[String]>([])
        let executor = MockExecutor { command, _ in
            let streams = "\(command.stdoutDestination)|\(command.stderrDestination)"
            seen.withLock { $0.append("\(command.executableName):\(streams)") }
            return ShellOutput(exitCode: 1)
        }
        let project = JavaScriptProject(root: scratch.url.path, shell: ShellContext(executor: executor))
        _ = try? await JestTestRunner(shell: ShellContext(executor: executor), output: .streamingToStderr).run(project: project)
        _ = try? await FlutterTestRunner(shell: ShellContext(executor: executor), output: .streamingToStderr)
            .runUnitTests(in: scratch.url.path)
        let calls = seen.withLock { $0 }
        let tee = "\(OutputDestination.teeTo(.stderr))"
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.hasSuffix("\(tee)|\(tee)") }, "Every command streams to stderr: \(calls)")
    }

    @Test("Jest needs the script to run Jest")
    func jestRequiresJest() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try Data(#"{"scripts": {"test": "mocha"}}"#.utf8).write(to: scratch.url.appending(path: "package.json"))
        try FileManager.default.createDirectory(at: scratch.url.appending(path: "node_modules"), withIntermediateDirectories: true)
        let project = JavaScriptProject(
            root: scratch.url.path, shell: ShellContext(executor: MockExecutor { _, _ in ShellOutput(exitCode: 0) }))
        #expect(project.packageManager == .npm)
        await #expect(throws: MobileKitError.self) { try await JestTestRunner().run(project: project) }
    }
}
