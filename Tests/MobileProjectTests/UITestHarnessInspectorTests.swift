import Foundation
import TestCommons
import Testing

@testable import MobileProject

@Suite("UITestHarnessInspector")
struct UITestHarnessInspectorTests {
    static let harness = #"""
        import XCTest
        import JotUIIdentifiers

        class JotUITestCase: XCTestCase {
            var app: XCUIApplication!
            private(set) var launchCount = 0

            func makeApplication() -> XCUIApplication {
                XCUIApplication().usingLanguage("en", locale: "en_US")
            }

            override func setUpWithError() throws {
                continueAfterFailure = false
                app = makeApplication()
                app.launch()   // "{" braces in comments and "}" strings must not confuse structure
            }

            func relaunchApplication(resetState: Bool = false) {
                app.terminate()
                app.launch()
            }

            func waitForExistence(_ element: XCUIElement, timeout: TimeInterval = UITestConstants.timeout) {
                XCTAssertTrue(element.waitForExistence(timeout: timeout))
            }

            private func waitForHittability(_ element: XCUIElement, timeout: TimeInterval = 5) {}

            func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = UITestConstants.timeout) {}
            func waitForAbsence(_ element: XCUIElement, polling: Bool) {}
        }

        extension XCUIApplication {
            func element(id: String) -> XCUIElement { descendants(matching: .any)[id] }
        }
        """#

    static let tests = #"""
        import XCTest

        final class HabitsUITests: JotUITestCase {
            func testAddHabit() {
                app.buttons[JotUIAutomationID.Tab.habits].tap()
                let message = "contains { and } braces"
                XCTAssertFalse(message.isEmpty)
            }
        }

        final class StandaloneUITests: XCTestCase {
            func testLaunch() { XCUIApplication().launch() }
        }
        """#

    static let identifiers = #"""
        public enum JotUIAutomationID {
            public enum Tab {
                public static let habits = "app.tab.habits"
                public static let today: String = "app.tab.today"
                #if DEBUG
                public static let debug = "app.tab.debug"
                #endif
            }
            public enum Duplicate {
                public static let one = "dup"
                public static let two = "dup"
                public static let dynamic = "app.\(1)"
            }
        }
        """#

    func fixture() throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        for (path, text) in [
            ("JotUITests/Support/JotUITestCase.swift", Self.harness), ("JotUITests/HabitsUITests.swift", Self.tests),
            ("JotUIIdentifiers/JotUIAutomationID.swift", Self.identifiers),
        ] {
            let url = scratch.url.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return scratch
    }

    @Test("Finds the shared base class and what it owns, launches, and lets subclasses override")
    func harnessFacts() throws {
        let scratch = try fixture()
        defer { try? scratch.remove() }
        let facts = UITestHarnessInspector().inspect(scratch.url.path)
        #expect(facts.uiTestFiles == ["JotUITests/HabitsUITests.swift", "JotUITests/Support/JotUITestCase.swift"])
        #expect(facts.baseClass?.value == "JotUITestCase")
        #expect(facts.baseClass?.evidence.first?.path == "JotUITests/Support/JotUITestCase.swift")
        #expect(facts.harnessOwnsApplication?.value == true)
        #expect(facts.harnessLaunchesApplication?.value == true)
        #expect(facts.applicationFactory?.value == "makeApplication()")
        #expect(facts.relaunchHelper?.template == "relaunchApplication()")
        #expect(facts.testDirectories == ["JotUITests"])
        #expect(facts.imports == ["JotUIIdentifiers"])
        #expect(facts.applicationExtensions == ["element(id:)"])
        #expect(Set(facts.testCaseClasses.map(\.value)) == ["HabitsUITests", "JotUITestCase", "StandaloneUITests"])
    }

    @Test("Private and overloaded helpers are never bound")
    func helpers() throws {
        let scratch = try fixture()
        defer { try? scratch.remove() }
        let facts = UITestHarnessInspector().inspect(scratch.url.path)
        #expect(facts.waitHelpers.keys.sorted() == ["waitForExistence"], "waitForHittability is private; waitForAbsence is overloaded")
        #expect(facts.waitHelpers["waitForExistence"]?.template == "waitForExistence({{element}})")
        #expect(facts.defaultTimeout?.value == "UITestConstants.timeout")
        #expect(facts.diagnostics.contains { $0.contains("waitForAbsence") })
    }

    @Test("The identifier catalog keeps unique literal constants, including ones in #if branches")
    func identifierCatalog() throws {
        let scratch = try fixture()
        defer { try? scratch.remove() }
        let catalog = UITestHarnessInspector().inspect(scratch.url.path).identifierCatalog
        #expect(catalog["app.tab.habits"] == "JotUIAutomationID.Tab.habits")
        #expect(catalog["app.tab.today"] == "JotUIAutomationID.Tab.today")
        #expect(catalog["app.tab.debug"] == "JotUIAutomationID.Tab.debug")
        #expect(catalog["dup"] == nil, "two constants name it")
        #expect(!catalog.keys.contains { $0.hasPrefix("app.\\") }, "interpolated strings are not literals")
    }

    @Test("Several distinct base classes are reported, not guessed")
    func ambiguousBase() {
        var index = SwiftDeclarationIndex()
        index.add(source: "import XCTest\nclass A: XCTestCase {}\nclass B: XCTestCase {}", path: "Base.swift")
        index.add(
            source: "import XCTest\nclass T1: A { func t() { XCUIApplication().launch() } }\nclass T2: B { let x = XCUIApplication() }",
            path: "UITests/T.swift")
        let facts = UITestHarnessInspector().inspect(index)
        #expect(facts.baseClass == nil)
        #expect(facts.diagnostics.contains { $0.contains("several base classes") })
    }
}
