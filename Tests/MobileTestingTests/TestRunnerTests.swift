import Foundation
import GradleKit
import MobileBuild
import MobileCore
import SwiftyShell
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
