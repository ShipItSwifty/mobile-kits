import Foundation
import MobileCore
import TestCommons
import Testing

@testable import MobileTesting

@Suite("JUnitTestParser")
struct JUnitTestParserTests {

    @Test("A large single report keeps every case in its own suite and counts every status once")
    func largeReportGroupsSuites() async throws {
        let scratch = try TemporaryDirectory(prefix: "JUnitTestParserLarge")
        defer { try? scratch.remove() }
        let directory = scratch.url.appendingPathComponent("app/build/test-results/test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteCount = 40
        let casesPerSuite = 150
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n"
        for suite in 0..<suiteCount {
            xml += "<testsuite name=\"com.example.Suite\(suite)\" tests=\"\(casesPerSuite)\" skipped=\"0\" failures=\"1\" errors=\"0\">\n"
            for index in 0..<casesPerSuite {
                let failure = index == 0 ? "<failure message=\"boom\">trace</failure>" : ""
                xml += "<testcase name=\"case\(index)\" classname=\"com.example.Suite\(suite)\" time=\"0.001\">\(failure)</testcase>\n"
            }
            xml += "</testsuite>\n"
        }
        xml += "</testsuites>\n"
        try Data(xml.utf8).write(to: directory.appendingPathComponent("TEST-all.xml"))

        let run = try await JUnitTestParser().parse(reportDirectory: directory.path, identityRoot: scratch.url.path)
        #expect(run.testCases.count == suiteCount * casesPerSuite)
        #expect(run.summary.failed == suiteCount)
        #expect(run.summary.passed == suiteCount * (casesPerSuite - 1))
        #expect(run.suites.count == suiteCount)
        #expect(run.suites.allSatisfy { $0.testCaseIDs.count == casesPerSuite })
        #expect(Set(run.suites.flatMap(\.testCaseIDs)).count == suiteCount * casesPerSuite)
        #expect(run.testCases.first?.metadata?["gradle_task"] == "test")
        #expect(run.testCases.first?.metadata?["module"] == "app")
    }

    @Test("Parses Gradle JUnit XML files into normalized suites and test cases")
    func parsesJUnitDirectory() async throws {
        let scratch = try TemporaryDirectory(prefix: "JUnitTestParser")
        defer { try? scratch.remove() }
        let root = scratch.url

        let reportDirectory = root.appendingPathComponent("app/build/test-results/testDebugUnitTest", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="com.example.CheckoutTests" tests="3" skipped="1" failures="1" errors="0">
              <testcase name="testHappyPath" classname="com.example.CheckoutTests" time="0.01"/>
              <testcase name="testNetworkError" classname="com.example.CheckoutTests" time="0.02">
                <failure message="boom"/>
              </testcase>
              <testcase name="testLegacyMode" classname="com.example.CheckoutTests" time="0.03">
                <skipped/>
              </testcase>
            </testsuite>
            """
        try xml.write(
            to: reportDirectory.appendingPathComponent("TEST-com.example.CheckoutTests.xml"),
            atomically: true,
            encoding: .utf8
        )

        let parser = JUnitTestParser()
        let run = try await parser.parse(reportDirectory: reportDirectory.path)

        #expect(run.runner == .gradle)
        #expect(run.destinations.isEmpty, "a bare report directory says nothing about where the tests ran")
        #expect(run.summary.passed == 1)
        #expect(run.summary.failed == 1)
        #expect(run.summary.skipped == 1)
        #expect(run.suites.count == 1)
        #expect(run.suites.first?.name == "com.example.CheckoutTests")
        #expect(run.testCases.count == 3)
        #expect(
            run.testCases.first(where: { $0.name == "testNetworkError" })?.rerunSelector
                == .gradleTestFilter("com.example.CheckoutTests.testNetworkError"))
    }

    @Test("Throws when the report directory has no JUnit XML files")
    func throwsWhenNoXMLFilesExist() async throws {
        let scratch = try TemporaryDirectory(prefix: "AndroidJUnitMissing")
        defer { try? scratch.remove() }
        let root = scratch.url

        do {
            _ = try await JUnitTestParser().parse(reportDirectory: root.path)
            Issue.record("Expected JUnitTestParser to throw for an empty directory")
        } catch let error as MobileKitError {
            guard case .invalidRequest = error else {
                Issue.record("Expected invalidRequest, got \(error)")
                return
            }
        }
    }
}
