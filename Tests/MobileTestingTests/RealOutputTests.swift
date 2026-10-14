import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import TestCommons
import Testing

@testable import MobileTesting

/// Replays artifacts captured from real tools (Gradle 9.8 with the `test-retry` plugin, `xcodebuild` and
/// `xcresulttool` on an iOS 27.2 simulator) instead of hand-written approximations. When a tool changes its
/// output, these fail first. See `Fixtures/real/README.md` for how each was captured.
@Suite("Real tool output")
struct RealFormatTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/real")

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Gradle with the test-retry plugin

    @Test("Real Gradle test-retry XML folds attempts into one test each")
    func gradleTestRetry() async throws {
        let directory = Self.root.appendingPathComponent("gradle-test-retry/build/test-results/test")
        let run = try await NativeResultReader(shell: .init()).read(directory.path, format: .junit, runner: .gradle)
        #expect(run.runner == .gradle)
        #expect(run.testCases.count == 4, "four tests, though the report holds seven entries (one per attempt)")
        func test(_ name: String) throws -> ParsedTestCase { try #require(run.testCases.first { $0.name == name }) }

        let flaky = try test("flaky()")
        #expect(flaky.status == .passed)
        #expect(flaky.attempts == 2)
        #expect(flaky.metadata?["flaky"] == "true")
        #expect(flaky.metadata?["first_failure"]?.contains("flaky first attempt") == true)

        let alwaysFails = try test("alwaysFails()")
        #expect(alwaysFails.status == .failed)
        #expect(alwaysFails.attempts == 3)
        #expect(alwaysFails.metadata?["flaky"] == nil)
        #expect(alwaysFails.stackTrace?.contains("ProbeTest.java:8") == true)
        #expect(alwaysFails.message?.contains("always fails") == true)

        #expect(try test("passes()").attempts == 1)
        #expect(try test("skipped()").status == .skipped)
        #expect(run.summary == .init(passed: 2, failed: 1, skipped: 1, flaky: 1, errored: 0))
        #expect(!run.diagnostics.contains { $0.severity == .warning }, "declared totals count attempts; the fold must account for that")
        #expect(run.destinations.map(\.platform) == [.jvm], "the plain `test` task of a JVM project")
        #expect(run.destinations.first?.scope == "test")
    }

    // MARK: xcodebuild and xcresulttool

    #if os(macOS)
    private func parse(_ directory: String) async throws -> ParsedTestRun {
        let summary = try Self.text("\(directory)/summary.json")
        let tests = try Self.text("\(directory)/tests.json")
        let executor = MockExecutor { command, _ in
            command.arguments.contains("summary")
                ? .init(stdout: summary, stderr: "", exitCode: 0) : .init(stdout: tests, stderr: "", exitCode: 0)
        }
        return try await IOSXCResultTestParser(shell: ShellContext(executor: executor)).parse(xcresultPath: "real.xcresult")
    }

    @Test("A real result bundle's device becomes a destination with its human name")
    func realXCResultDestination() async throws {
        let run = try await parse("xcresult-recovered")
        #expect(run.runner == .xcodebuild)
        #expect(run.testCases.map(\.name).sorted() == ["testArithmetic()", "testBundleIdentifier()"])
        #expect(run.summary.passed == 2)
        let destination = try #require(run.destinations.first)
        #expect(run.destinations.count == 1)
        #expect(destination.platform == .ios)
        #expect(destination.kind == .simulator, "`platform` is \"iOS Simulator\" in real output")
        #expect(destination.name == "iPhone 17")
        #expect(run.testCases.allSatisfy { $0.destinationID == destination.id })
    }

    @Test("A real simulator clone failure is one failed pseudo-test carrying the clone message")
    func realCloneFailure() async throws {
        let run = try await parse("xcresult-clone-failure")
        let failure = try #require(run.testCases.first)
        #expect(run.testCases.count == 1)
        #expect(failure.name == "The test runner encountered an error")
        #expect(failure.status == .failed)
        #expect(failure.message?.contains("Failed to clone device named 'iPhone 17'") == true)
    }
    #endif
}

@Suite("Real Flutter machine output")
struct RealFlutterTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/real/flutter-machine")

    private func parse(_ name: String) async throws -> ParsedTestRun {
        let events = try String(contentsOf: Self.directory.appendingPathComponent(name), encoding: .utf8)
        return try await FlutterMachineOutputParser().parse(machineOutput: events)
    }

    private func status(_ run: ParsedTestRun, _ name: String) throws -> TestCaseStatus {
        try #require(run.testCases.first { $0.name == name }, "no test named \(name)").status
    }

    @Test("A real failing run: failures keep their message and stack, the skip is a skip, the loading pseudo-test is hidden")
    func realFirstAttempt() async throws {
        let run = try await parse("first-attempt.jsonl")
        #expect(run.runner == .flutterTest)
        #expect(run.framework == .flutter)
        #expect(run.testCases.count == 4, "the hidden `loading <file>` test is not a test")
        #expect(try status(run, "Scripted passes") == .passed)
        #expect(try status(run, "Scripted skipped on purpose") == .skipped, "`skipped: true` arrives with `result: success`")
        #expect(try status(run, "Scripted flaky") == .failed)
        #expect(try status(run, "Scripted always fails when asked") == .failed)
        #expect(run.summary == .init(passed: 1, failed: 2, skipped: 1, flaky: 0, errored: 0))
        let flaky = try #require(run.testCases.first { $0.name == "Scripted flaky" })
        #expect(flaky.message?.contains("fails on the first attempt only") == true)
        #expect(flaky.message?.contains("scripted_test.dart") == true, "the stack trace from the error event is kept")
        #expect(flaky.attempts == 1)
    }

    @Test("Real output is not pure JSONL: text before the events and JSON arrays are tolerated")
    func realOutputHasNoise() throws {
        let lines = try String(contentsOf: Self.directory.appendingPathComponent("first-attempt.jsonl"), encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        let objects = lines.filter { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) is [String: Any] }
        #expect(lines.count > objects.count, "the capture really contains non-event lines")
        #expect(lines.contains { !$0.hasPrefix("{") && !$0.hasPrefix("[") }, "plain text from `flutter pub get`")
        #expect(lines.contains { $0.hasPrefix("[") }, "VM-service events arrive as JSON arrays")
    }

    @Test("A rerun by name renumbers every event ID, yet each test keeps the stable ID it had before")
    func realRerunKeepsIdentity() async throws {
        let first = try await parse("first-attempt.jsonl")
        let rerun = try await parse("rerun-by-name.jsonl")
        #expect(rerun.testCases.count == 2)
        #expect(try status(rerun, "Scripted flaky") == .passed, "its marker exists now")
        #expect(try status(rerun, "Scripted always fails when asked") == .failed)
        for name in ["Scripted flaky", "Scripted always fails when asked"] {
            let before = try #require(first.testCases.first { $0.name == name })
            let after = try #require(rerun.testCases.first { $0.name == name })
            #expect(before.stableID == after.stableID, "\(name) must reconcile across attempts")
        }
        // The rerun selector is the name, matching what `flutter test --name` needs.
        let flaky = try #require(first.testCases.first { $0.name == "Scripted flaky" })
        #expect(flaky.rerunSelector == .flutter(name: "Scripted flaky"))
    }

    @Test("A real all-passing run, and a flaky-only run, summarize correctly")
    func realPassingAndFlakyOnly() async throws {
        let passing = try await parse("all-passing.jsonl")
        #expect(passing.summary == .init(passed: 3, failed: 0, skipped: 1, flaky: 0, errored: 0))
        let flakyOnly = try await parse("flaky-only-first-attempt.jsonl")
        #expect(flakyOnly.summary == .init(passed: 2, failed: 1, skipped: 1, flaky: 0, errored: 0))
    }

    @Test("Saved real events are detected and read the same through the shared reader")
    func realFileThroughSharedReader() async throws {
        let path = Self.directory.appendingPathComponent("first-attempt.jsonl").path
        let run = try await NativeResultReader(shell: .init()).read(path)
        #expect(run.runner == .flutterTest)
        #expect(run.testCases.count == 4)
        #expect(run.destinations.isEmpty, "saved events do not say where the tests ran")
    }
}

@Suite("Real Jest output")
struct RealJestTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/real/jest")

    private func parse(_ name: String) async throws -> ParsedTestRun {
        try await JestJSONTestParser().parse(
            jsonFilePath: Self.directory.appendingPathComponent(name).path, framework: .reactNative, identityRoot: "/project")
    }

    private func test(_ name: String, in run: ParsedTestRun) throws -> ParsedTestCase {
        try #require(run.testCases.first { $0.name == name }, "no test named \(name)")
    }

    @Test("A real Jest run: identities are relative to the project, and every test records where it ran")
    func realFirstAttempt() async throws {
        let run = try await parse("first-attempt.json")
        #expect(run.runner == .jest)
        #expect(run.framework == .reactNative)
        #expect(run.destinations == [TestDestination(platform: .js, kind: .host)])
        #expect(run.testCases.count == 40)
        #expect(run.summary.failed == 2)
        #expect(run.summary.skipped == 1)
        #expect(run.summary.passed == 37)
        let flaky = try test("flaky", in: run)
        #expect(flaky.status == .failed)
        #expect(flaky.stableID == "jest-case:__tests__/scripted.test.js::Scripted flaky", "no machine-specific path")
        #expect(flaky.rerunSelector == .jest(file: "__tests__/scripted.test.js", fullName: "Scripted flaky"))
        #expect(flaky.message?.contains("Expected: false") == true)
        #expect(run.testCases.allSatisfy { !$0.stableID.hasPrefix("jest-case:/") }, "no absolute paths in any identity")
        #expect(run.testCases.allSatisfy { $0.attempts == 1 && $0.destinationID == "js:host" })
        #expect(run.suites.allSatisfy { !$0.name.hasPrefix("/") })
    }

    @Test("A rerun by name reports the unselected tests as skipped, so they resolve nothing")
    func realRerun() async throws {
        let first = try await parse("first-attempt.json")
        let rerun = try await parse("rerun-by-name.json")
        #expect(try test("flaky", in: rerun).status == .passed, "its marker exists now")
        #expect(try test("always fails when asked", in: rerun).status == .failed)
        #expect(try test("passes", in: rerun).status == .skipped, "not selected by the pattern")
        for name in ["flaky", "always fails when asked"] {
            #expect(try test(name, in: first).stableID == (try test(name, in: rerun).stableID), "\(name) reconciles across attempts")
        }
    }

    @Test("Saved Jest JSON read offline gets the same identities as a live run, by finding the project's package.json")
    func realJestOffline() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let project = scratch.url.appendingPathComponent("app")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("build/test-runs/attempt-1"), withIntermediateDirectories: true)
        try "{}".write(to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        // The same Jest JSON, but with this scratch project as its root: paths are rewritten from the scrubbed `/project/`.
        let json = try String(contentsOf: Self.directory.appendingPathComponent("first-attempt.json"), encoding: .utf8)
            .replacingOccurrences(of: "/project/", with: project.resolvingSymlinksInPath().path + "/")
        let saved = project.appendingPathComponent("build/test-runs/attempt-1/jest.json")
        try json.write(to: saved, atomically: true, encoding: .utf8)
        let run = try await NativeResultReader(shell: .init()).read(saved.path, format: .jest)
        #expect(run.testCases.contains { $0.stableID == "jest-case:__tests__/scripted.test.js::Scripted flaky" })
        #expect(run.testCases.allSatisfy { !$0.stableID.hasPrefix("jest-case:/") })
    }

}

@Suite("Real Swift Testing events")
struct RealSwiftTestingTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/real")

    @Test("Tests in nested suites keep separate identities without their source location")
    func swiftTestingNestedSuites() throws {
        let run = try SwiftEventParser().parse(path: Self.root.appendingPathComponent("swift-testing-events/nested-suites.jsonl").path)
        let ids = run.testCases.map(\.stableID)
        #expect(
            ids == [
                "swift-case:LibTests.Outer/Inner/alpha()", "swift-case:LibTests.Outer/Inner/beta()",
                "swift-case:LibTests.Outer/Inner/gamma()", "swift-case:LibTests.param(_:)", "swift-case:LibTests.topLevel()",
            ])
        #expect(Set(ids).count == ids.count, "every test has its own identity")
        func status(_ name: String) -> TestCaseStatus? { run.testCases.first { $0.name == name }?.status }
        #expect(status("alpha()") == .passed)
        #expect(status("beta()") == .failed)
        #expect(status("gamma()") == .failed)
        #expect(status("param(_:)") == .failed, "one failing argument fails the parameterized test")
        #expect(run.testCases.first { $0.name == "gamma()" }?.rerunSelector == .swiftTestFilter("LibTests.Outer/Inner/gamma()"))
    }

    @Test(
        "A Swift Testing ID loses only its trailing source location",
        arguments: [
            ("M.S/t()/S.swift:3:4", "M.S/t()"),
            ("M.Outer/Inner/Deeper/t()/S.swift:10:2", "M.Outer/Inner/Deeper/t()"),
            ("M.free()/S.swift:1:1", "M.free()"),
            ("M.S", "M.S"),
        ])
    func swiftTestingSelector(id: String, expected: String) {
        #expect(SwiftEventParser.selector(forTestID: id) == expected)
    }
}
