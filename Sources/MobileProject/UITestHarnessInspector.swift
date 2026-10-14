import Foundation
import Logging
import MobileCore

/// What a repository's Swift UI-test harness provides, found by parsing its sources.
///
/// Candidates, not decisions: a value is set only when exactly one declaration supports it;
/// otherwise the alternatives are in ``diagnostics``. Whether generated tests may rely on a
/// binding is the consumer's call, after compiling them in the real target.
public struct UITestHarnessFacts: Sendable {
    /// A helper usable from a generated subclass: name, call template, and where it is declared.
    public struct Helper: Sendable, Hashable {
        /// `waitForExistence(_:timeout:)`.
        public var selector: String
        /// `waitForExistence({{element}})`, with every defaulted parameter left out.
        public var template: String
        public var evidence: Evidence
    }

    /// Files that drive `XCUIApplication`.
    public var uiTestFiles: [String]
    /// UI test case classes (XCTestCase subclasses in those files).
    public var testCaseClasses: [Finding<String>]
    /// The single local base class the UI tests share, when there is exactly one.
    public var baseClass: Finding<String>?
    /// Whether the base class (or its ancestors) declares a non-private `app` property.
    public var harnessOwnsApplication: Finding<Bool>?
    /// Whether `setUp` in the base chain calls `<app>.launch()`.
    public var harnessLaunchesApplication: Finding<Bool>?
    /// An overridable `makeApplication()` factory.
    public var applicationFactory: Finding<String>?
    /// A `relaunchApplication()`-style helper callable without arguments.
    public var relaunchHelper: Helper?
    /// Single-element wait helpers keyed by name.
    public var waitHelpers: [String: Helper]
    /// The default `timeout:` expression the helpers share, when they agree.
    public var defaultTimeout: Finding<String>?
    /// Raw accessibility identifier to the repository constant naming it, from enums ending
    /// in `AutomationID` or `AccessibilityID`. Identifiers named by more than one constant are left out.
    public var identifierCatalog: [String: String]
    /// Methods declared in `extension XCUIApplication` / `extension XCUIElement`, e.g. `element(id:)`.
    public var applicationExtensions: [String]
    /// Modules the UI tests import, other than XCTest.
    public var imports: [String]
    /// Directories holding UI test files, candidates for the generated-test target.
    public var testDirectories: [String]
    public var diagnostics: [String]
}

/// Builds ``UITestHarnessFacts`` from Swift sources with SwiftSyntax.
public struct UITestHarnessInspector: Sendable {
    public var excludedDirectories: Set<String>
    public var maximumFileBytes: Int
    private let logger = Logger.forType(UITestHarnessInspector.self)

    public init(excludedDirectories: Set<String> = RepositoryInspector.defaultExclusions, maximumFileBytes: Int = 2_000_000) {
        self.excludedDirectories = excludedDirectories
        self.maximumFileBytes = maximumFileBytes
    }

    /// Parses every Swift file under `root`.
    public func index(_ root: String) -> SwiftDeclarationIndex {
        let base = URL(fileURLWithPath: root).standardizedFileURL
        var index = SwiftDeclarationIndex()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return index
        }
        var files: [(String, URL)] = []
        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension == "swift", (values?.fileSize ?? 0) <= maximumFileBytes else { continue }
            files.append((String(url.standardizedFileURL.path.dropFirst(base.path.count + 1)), url))
        }
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            index.add(source: source, path: relative)
        }
        return index
    }

    public func inspect(_ root: String) -> UITestHarnessFacts {
        logger.info("Inspecting UI-test harness", metadata: ["root": "\(root)"])
        let facts = inspect(index(root))
        logger.info(
            "UI-test harness inspected",
            metadata: [
                "files": "\(facts.uiTestFiles.count)", "base": "\(facts.baseClass?.value ?? "-")",
                "ids": "\(facts.identifierCatalog.count)",
            ])
        return facts
    }

    public func inspect(_ index: SwiftDeclarationIndex) -> UITestHarnessFacts {
        var diagnostics: [String] = []
        let uiFiles = index.files.filter { index.identifiersByFile[$0]?.contains("XCUIApplication") == true }.sorted()
        let uiFileSet = Set(uiFiles)
        let testCases = index.types.filter {
            $0.kind == .class && uiFileSet.contains($0.file) && index.inherits($0, from: "XCTestCase")
        }

        // The base: a local superclass of UI test cases that is not itself generated output.
        let parents = Set(testCases.compactMap { $0.inherited.first }).filter { name in
            !index.classes(named: name).isEmpty && !name.contains("Generated")
        }
        let leafParents = parents.filter { parent in
            // Prefer the most derived shared parent: drop a parent that is itself a parent's ancestor.
            !parents.contains { other in
                other != parent
                    && index.classes(named: other).first.map { index.superclassChain(of: $0).contains { $0.name == parent } } == true
            }
        }
        var baseDeclaration: SwiftDeclarationIndex.TypeDeclaration?
        if leafParents.count == 1, let name = leafParents.first, let declaration = index.classes(named: name).first,
            index.classes(named: name).count == 1
        {
            baseDeclaration = declaration
        } else if leafParents.count > 1 {
            diagnostics.append("UI tests use several base classes: \(leafParents.sorted().joined(separator: ", "))")
        }

        let chain = baseDeclaration.map { [$0] + index.superclassChain(of: $0) } ?? []
        let members =
            chain.flatMap(\.functions)
            + index.types.filter { chain.map(\.name).contains($0.name) && $0.kind == .extension }.flatMap(\.functions)

        // Application property.
        let appProperty = chain.flatMap(\.properties).first { $0.name == "app" && !$0.isStatic }
        let ownsApplication = baseDeclaration.map { _ in
            Finding(
                appProperty.map { $0.access.isVisibleToModule } ?? false,
                evidence: appProperty.map { [Evidence(path: $0.file, line: $0.line, detail: "\($0.isLet ? "let" : "var") app")] } ?? [],
                strength: .declared)
        }

        // setUp launches.
        let setUps = chain.flatMap(\.functions).filter { ["setUp", "setUpWithError"].contains($0.name) }
        let launch = setUps.first { $0.calls.contains { $0 == "app.launch" || $0.hasSuffix("pplication.launch") || $0 == "launch" } }
        let launchesApplication = baseDeclaration.map { _ in
            Finding(
                launch != nil,
                evidence: (launch ?? setUps.first).map { [Evidence(path: $0.file, line: $0.line, detail: $0.name)] } ?? [],
                strength: .declared)
        }

        // Overridable factory.
        let factory = chain.flatMap(\.functions).first {
            $0.name == "makeApplication" && $0.parameters.isEmpty && $0.access.isVisibleToModule && !$0.isFinal && !$0.isStatic
        }
        let applicationFactory = factory.map {
            Finding("makeApplication()", evidence: [Evidence(path: $0.file, line: $0.line, detail: $0.returnType)], strength: .declared)
        }

        // Relaunch helper: callable with no arguments.
        let relaunch = members.first {
            $0.name.lowercased().hasPrefix("relaunch") && $0.access.isVisibleToModule && $0.parameters.allSatisfy { $0.defaultValue != nil }
        }
        let relaunchHelper = relaunch.map {
            UITestHarnessFacts.Helper(selector: $0.selector, template: "\($0.name)()", evidence: Evidence(path: $0.file, line: $0.line))
        }

        // Single-element wait helpers, from the harness and any XCTestCase extension. A name
        // declared more than once is ambiguous even when only one overload would qualify.
        let helperScope = members + index.types.filter { $0.kind == .extension && $0.name == "XCTestCase" }.flatMap(\.functions)
        let declarationCounts = Dictionary(grouping: helperScope.filter { $0.name.hasPrefix("waitFor") }, by: \.name).mapValues(\.count)
        let waitCandidates =
            helperScope
            .filter { function in
                guard function.name.hasPrefix("waitFor"), function.access.isVisibleToModule, let first = function.parameters.first else {
                    return false
                }
                return first.label == "_" && first.type.contains("XCUIElement")
                    && function.parameters.dropFirst().allSatisfy { $0.defaultValue != nil }
            }
        var waitHelpers: [String: UITestHarnessFacts.Helper] = [:]
        for (name, functions) in Dictionary(grouping: waitCandidates, by: \.name).sorted(by: { $0.key < $1.key }) {
            let declared = declarationCounts[name] ?? functions.count
            guard declared == 1, let function = functions.first else {
                diagnostics.append("\(name) is declared \(declared) times; not bound")
                continue
            }
            waitHelpers[name] = .init(
                selector: function.selector, template: "\(name)({{element}})", evidence: Evidence(path: function.file, line: function.line))
        }

        // Default timeout: every helper's `timeout:` default agrees.
        let timeouts = Set(
            waitCandidates.flatMap(\.parameters).filter { $0.name == "timeout" || $0.label == "timeout" }.compactMap(\.defaultValue))
        let defaultTimeout: Finding<String>? =
            timeouts.count == 1
            ? timeouts.first.map { value in
                Finding(
                    value,
                    evidence: waitCandidates.filter { $0.parameters.contains { $0.defaultValue == value } }.map {
                        Evidence(path: $0.file, line: $0.line, detail: "timeout = \(value)")
                    }, strength: .declared)
            } : nil
        if timeouts.count > 1 {
            diagnostics.append("Wait helpers use different default timeouts: \(timeouts.sorted().joined(separator: ", "))")
        }

        // Identifier catalog: string constants inside *AutomationID / *AccessibilityID enums (and their nested enums).
        var candidates: [String: Set<String>] = [:]
        for type in index.types where type.kind == .enum || type.kind == .struct {
            guard let root = type.qualifiedName.split(separator: ".").first,
                root.hasSuffix("AutomationID") || root.hasSuffix("AccessibilityID") || root.hasSuffix("AccessibilityIdentifier")
            else { continue }
            for property in type.properties where property.isStatic {
                if let value = property.stringLiteral { candidates[value, default: []].insert("\(type.qualifiedName).\(property.name)") }
            }
        }
        let catalog = candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
        let ambiguous = candidates.filter { $0.value.count > 1 }.keys.sorted()
        if !ambiguous.isEmpty {
            diagnostics.append("Identifiers named by several constants: \(ambiguous.prefix(10).joined(separator: ", "))")
        }

        let extensions = index.types
            .filter { $0.kind == .extension && ($0.name == "XCUIApplication" || $0.name == "XCUIElement") }
            .flatMap(\.functions).filter { $0.access.isVisibleToModule }.map(\.selector)
        let imports = Set(index.imports.filter { uiFileSet.contains($0.file) }.map(\.module)).subtracting(["XCTest", "Foundation"])
        let directories = Set(
            uiFiles.compactMap { path -> String? in
                let components = path.split(separator: "/").dropLast()
                guard let last = components.lastIndex(where: { $0.hasSuffix("UITests") }) else { return nil }
                return components[...last].joined(separator: "/")
            })
        if directories.count > 1 {
            diagnostics.append("UI tests live in several directories: \(directories.sorted().joined(separator: ", "))")
        }

        return UITestHarnessFacts(
            uiTestFiles: uiFiles,
            testCaseClasses: testCases.map {
                Finding(
                    $0.qualifiedName, evidence: [Evidence(path: $0.file, line: $0.line, detail: $0.inherited.first)], strength: .declared)
            },
            baseClass: baseDeclaration.map {
                Finding($0.name, evidence: [Evidence(path: $0.file, line: $0.line, detail: $0.inherited.first)], strength: .declared)
            },
            harnessOwnsApplication: ownsApplication,
            harnessLaunchesApplication: launchesApplication,
            applicationFactory: applicationFactory,
            relaunchHelper: relaunchHelper,
            waitHelpers: waitHelpers,
            defaultTimeout: defaultTimeout,
            identifierCatalog: catalog,
            applicationExtensions: Array(Set(extensions)).sorted(),
            imports: imports.sorted(),
            testDirectories: directories.sorted(),
            diagnostics: diagnostics)
    }
}
