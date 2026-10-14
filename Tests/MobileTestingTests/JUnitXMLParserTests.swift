import Foundation
import Testing

@testable import MobileTesting

@Suite("JUnit XML Report Parsing")
struct JUnitXMLParserTests {

    @Test("Parses basic testsuite attributes")
    func parsesBasicTestsuite() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="com.example.MyTest" tests="10" skipped="1" failures="2" errors="0" time="0.5">
              <testcase name="testA" classname="com.example.MyTest" time="0.01"/>
            </testsuite>
            """
        let parser = JUnitXMLParser(data: Data(xml.utf8))
        parser.parse()

        #expect(parser.tests == 10)
        #expect(parser.failures == 2)
        #expect(parser.errors == 0)
        #expect(parser.skipped == 1)
        #expect(parser.testCases.map(\.name) == ["com.example.MyTest.testA"])
    }

    @Test("Handles errors attribute")
    func parsesErrors() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="com.example.ErrorTest" tests="5" skipped="0" failures="1" errors="2" time="1.0">
            </testsuite>
            """
        let parser = JUnitXMLParser(data: Data(xml.utf8))
        parser.parse()

        #expect(parser.tests == 5)
        #expect(parser.failures == 1)
        #expect(parser.errors == 2)
        #expect(parser.skipped == 0)
    }

    @Test("Returns zeros for empty or malformed XML")
    func handlesEmptyXML() {
        let parser = JUnitXMLParser(data: Data("not xml".utf8))
        parser.parse()

        #expect(parser.tests == 0)
        #expect(parser.failures == 0)
        #expect(parser.errors == 0)
        #expect(parser.skipped == 0)
    }

    @Test("Only reads first testsuite element")
    func onlyReadsFirstTestsuite() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites>
              <testsuite name="First" tests="3" skipped="0" failures="1" errors="0">
              </testsuite>
              <testsuite name="Second" tests="99" skipped="99" failures="99" errors="99">
              </testsuite>
            </testsuites>
            """
        let parser = JUnitXMLParser(data: Data(xml.utf8))
        parser.parse()

        #expect(parser.tests == 3)
        #expect(parser.failures == 1)
    }
}
