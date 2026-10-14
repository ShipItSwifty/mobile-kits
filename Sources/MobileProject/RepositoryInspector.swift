import Foundation
import Logging
import MobileCore

/// Where a fact came from, so a person (or agent) can check it.
public struct Evidence: Codable, Sendable, Hashable {
    /// Path relative to the inspected root.
    public var path: String
    public var line: Int?
    /// What was found there, e.g. `kotlin("multiplatform")`.
    public var detail: String?

    public init(path: String, line: Int? = nil, detail: String? = nil) {
        self.path = path
        self.line = line
        self.detail = detail
    }
}

/// How much a fact can be trusted.
public enum EvidenceStrength: String, Codable, Sendable, Comparable {
    /// A marker, name, or layout convention.
    case heuristic
    /// A parsed declaration or structured file.
    case declared

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs == .heuristic && rhs == .declared }
}

/// A fact with its evidence.
public struct Finding<Value: Sendable & Hashable>: Sendable, Hashable {
    public var value: Value
    public var evidence: [Evidence]
    public var strength: EvidenceStrength

    public init(_ value: Value, evidence: [Evidence], strength: EvidenceStrength) {
        self.value = value
        self.evidence = evidence
        self.strength = strength
    }
}

extension Finding: Codable where Value: Codable {}

/// A Gradle module and the Android identifiers its build file declares.
public struct GradleModule: Codable, Sendable, Hashable {
    /// `:app`.
    public var path: String
    /// Directory relative to the root.
    public var directory: String
    public var appliesAndroidApplication: Bool
    public var appliesAndroidLibrary: Bool
    public var appliesKotlinMultiplatform: Bool
    /// `namespace = "…"`: the R/BuildConfig package, not necessarily the installed id.
    public var namespace: String?
    /// `applicationId = "…"`: the installed package. `nil` when computed or inherited.
    public var applicationID: String?
    /// `testApplicationId`, else `<applicationId>.test` when an application id is declared.
    public var testApplicationID: String?
}

/// What the build tools in a repository are, without running any of them.
public struct RepositoryInspection: Sendable {
    public var root: String
    /// Every framework with evidence; a repository can hold several (an RN app with a native module).
    public var frameworks: [Finding<AppFramework>]
    /// Every build backend with evidence.
    public var backends: [Finding<BuildBackend>]
    /// `.xcodeproj` bundles, relative paths.
    public var xcodeProjects: [String]
    /// `.xcworkspace` bundles not nested in a project.
    public var xcodeWorkspaces: [String]
    public var testPlans: [String]
    /// Directories with a `Package.swift`.
    public var swiftPackages: [String]
    /// Directories with `settings.gradle[.kts]`.
    public var gradleRoots: [String]
    public var gradleModules: [GradleModule]
    /// `project.yml` (XcodeGen) and `Project.swift`/`Workspace.swift` (Tuist) manifests.
    public var projectGenerators: [Finding<String>]
    /// Directories whose name ends in `UITests` or `Tests`, as candidates; target membership is
    /// unresolved until a project tool confirms it.
    public var testDirectories: [String]
    public var limitations: [String]

    /// The framework existing tooling treats as the app's: Flutter, then React Native, then KMP,
    /// else native. Use ``frameworks`` to see every candidate.
    public var primaryFramework: AppFramework {
        for candidate in [AppFramework.flutter, .reactNative, .kmp] where frameworks.contains(where: { $0.value == candidate }) {
            return candidate
        }
        return .native
    }
}

/// Read-only inspection of a repository: files are read, never executed. Evaluating
/// `Package.swift`, Gradle scripts, or Tuist manifests runs repository code, so it is never
/// done here (use the build tools explicitly when that is wanted).
public struct RepositoryInspector: Sendable {
    public var excludedDirectories: Set<String>
    /// Stops walking below this depth, so a huge monorepo cannot stall inspection.
    public var maximumDepth: Int
    public var maximumFiles: Int
    private let logger = Logger.forType(RepositoryInspector.self)

    public static let defaultExclusions: Set<String> = [
        ".git", ".build", ".build-linux", "build", "DerivedData", "Pods", "node_modules", ".swiftpm", ".gradle", "vendor",
        "Carthage", ".dart_tool", "bazel-out", "bazel-bin", "bazel-testlogs",
    ]

    public init(excludedDirectories: Set<String> = Self.defaultExclusions, maximumDepth: Int = 8, maximumFiles: Int = 50_000) {
        self.excludedDirectories = excludedDirectories
        self.maximumDepth = maximumDepth
        self.maximumFiles = maximumFiles
    }

    public func inspect(_ rootPath: String) -> RepositoryInspection {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        logger.info("Inspecting repository", metadata: ["root": "\(root.path)"])
        var result = RepositoryInspection(
            root: root.path, frameworks: [], backends: [], xcodeProjects: [], xcodeWorkspaces: [], testPlans: [], swiftPackages: [],
            gradleRoots: [], gradleModules: [], projectGenerators: [], testDirectories: [], limitations: [])
        var frameworks: [AppFramework: [Evidence]] = [:]
        var backends: [BuildBackend: [Evidence]] = [:]
        var visited = 0
        let rootDepth = root.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            result.limitations.append("Cannot read \(root.path)")
            return result
        }
        while let url = walker.nextObject() as? URL {
            visited += 1
            if visited > maximumFiles {
                result.limitations.append("Stopped after \(maximumFiles) entries; deeper projects are not listed")
                break
            }
            let name = url.lastPathComponent
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/"))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if excludedDirectories.contains(name) || (name.hasPrefix(".") && name != ".") {
                    walker.skipDescendants()
                    continue
                }
                if url.pathComponents.count - rootDepth >= maximumDepth { walker.skipDescendants() }
                switch url.pathExtension {
                case "xcodeproj":
                    result.xcodeProjects.append(relative)
                    backends[.xcodebuild, default: []].append(Evidence(path: relative))
                    walker.skipDescendants()
                    continue
                case "xcworkspace":
                    result.xcodeWorkspaces.append(relative)
                    backends[.xcodebuild, default: []].append(Evidence(path: relative))
                    walker.skipDescendants()
                    continue
                default: break
                }
                if name.hasSuffix("UITests") || name.hasSuffix("Tests") || name == "integration_test" || name == "androidTest" {
                    result.testDirectories.append(relative)
                }
                continue
            }
            let directory = (relative as NSString).deletingLastPathComponent
            switch name {
            case "Package.swift" where directory.split(separator: "/").last == "Tuist":
                // Tuist's own dependency manifest, not a Swift package of the app.
                result.projectGenerators.append(Finding("tuist", evidence: [Evidence(path: relative)], strength: .declared))
            case "Package.swift":
                result.swiftPackages.append(directory.isEmpty ? "." : directory)
                backends[.swiftPM, default: []].append(Evidence(path: relative))
            case "settings.gradle", "settings.gradle.kts":
                result.gradleRoots.append(directory.isEmpty ? "." : directory)
                backends[.gradle, default: []].append(Evidence(path: relative))
                result.gradleModules += Self.gradleModules(settings: url, root: root)
            case "pubspec.yaml":
                if let text = try? String(contentsOf: url, encoding: .utf8), let line = Self.line(matching: #"^flutter:"#, in: text) {
                    frameworks[.flutter, default: []].append(Evidence(path: relative, line: line, detail: "flutter:"))
                    backends[.flutter, default: []].append(Evidence(path: relative, line: line))
                }
            case "package.json":
                if let dependency = Self.reactNativeDependency(url) {
                    frameworks[.reactNative, default: []].append(Evidence(path: relative, detail: dependency))
                    backends[.reactNative, default: []].append(Evidence(path: relative, detail: dependency))
                }
            case "build.gradle", "build.gradle.kts", "libs.versions.toml":
                if let text = try? String(contentsOf: url, encoding: .utf8),
                    let line = Self.line(
                        matching: #"kotlin\("multiplatform"\)|org\.jetbrains\.kotlin\.multiplatform|kotlin-multiplatform"#, in: text)
                {
                    frameworks[.kmp, default: []].append(Evidence(path: relative, line: line, detail: "Kotlin Multiplatform plugin"))
                }
            case "MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel":
                backends[.bazel, default: []].append(Evidence(path: relative))
            case "project.yml":
                result.projectGenerators.append(Finding("xcodegen", evidence: [Evidence(path: relative)], strength: .heuristic))
            case "Project.swift", "Workspace.swift":
                result.projectGenerators.append(Finding("tuist", evidence: [Evidence(path: relative)], strength: .declared))
            default:
                if url.pathExtension == "xctestplan" { result.testPlans.append(relative) }
            }
        }
        // Swift and Kotlin native apps are "native" when nothing cross-platform was found next to them.
        if frameworks.isEmpty, !result.xcodeProjects.isEmpty || !result.gradleRoots.isEmpty || !result.swiftPackages.isEmpty {
            frameworks[.native] = (result.xcodeProjects + result.gradleRoots.map { $0 + "/settings.gradle" }).map { Evidence(path: $0) }
        }
        result.frameworks = frameworks.keys.sorted { $0.rawValue < $1.rawValue }.map {
            Finding($0, evidence: frameworks[$0] ?? [], strength: $0 == .native ? .heuristic : .declared)
        }
        result.backends = backends.keys.sorted { $0.rawValue < $1.rawValue }.map {
            Finding($0, evidence: backends[$0] ?? [], strength: .declared)
        }
        for keyPath in [
            \RepositoryInspection.xcodeProjects, \.xcodeWorkspaces, \.testPlans, \.swiftPackages, \.gradleRoots, \.testDirectories,
        ] {
            result[keyPath: keyPath].sort()
        }
        logger.info(
            "Repository inspected",
            metadata: ["frameworks": "\(result.frameworks.map(\.value.rawValue))", "projects": "\(result.xcodeProjects.count)"])
        return result
    }

    // MARK: - File readers

    static func line(matching pattern: String, in text: String) -> Int? {
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.range(of: pattern, options: .regularExpression) != nil {
            return index + 1
        }
        return nil
    }

    static func reactNativeDependency(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let dependencies = (json["dependencies"] as? [String: Any] ?? [:]).merging(json["devDependencies"] as? [String: Any] ?? [:]) {
            a, _ in a
        }
        if let version = dependencies["react-native"] { return "react-native \(version)" }
        if let version = dependencies["expo"] { return "expo \(version)" }
        return nil
    }

    /// Modules from `include(":app", ":feature:login")` / `include ':app'` in a settings file.
    /// Computed includes are not evaluated; they are simply absent.
    static func gradleModules(settings: URL, root: URL) -> [GradleModule] {
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return [] }
        let base = settings.deletingLastPathComponent()
        var modules: [GradleModule] = []
        let regex = try? NSRegularExpression(pattern: #"['"](:[\w\-:.]+)['"]"#)
        for line in text.split(separator: "\n") where line.contains("include") {
            let string = String(line)
            for match in regex?.matches(in: string, range: NSRange(string.startIndex..., in: string)) ?? [] {
                guard let range = Range(match.range(at: 1), in: string) else { continue }
                let path = String(string[range])
                let directory = base.appendingPathComponent(path.split(separator: ":").joined(separator: "/"))
                modules.append(gradleModule(path: path, directory: directory, root: root))
            }
        }
        return modules
    }

    static func gradleModule(path: String, directory: URL, root: URL) -> GradleModule {
        let text =
            ["build.gradle.kts", "build.gradle"].lazy
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
            .first ?? ""
        func literal(_ key: String) -> String? {
            let pattern = #"\b"# + key + #"\s*=?\s*["']([^"'$]+)["']"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        let applicationID = literal("applicationId")
        return GradleModule(
            path: path,
            directory: String(directory.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")),
            appliesAndroidApplication: text.contains("com.android.application") || text.contains("android.application"),
            appliesAndroidLibrary: text.contains("com.android.library") || text.contains("android.library"),
            appliesKotlinMultiplatform: text.contains("kotlin(\"multiplatform\")") || text.contains("kotlin.multiplatform")
                || text.contains("kotlinMultiplatform"),
            namespace: literal("namespace"),
            applicationID: applicationID,
            testApplicationID: literal("testApplicationId") ?? applicationID.map { $0 + ".test" })
    }
}
