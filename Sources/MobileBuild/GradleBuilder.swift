import Foundation
import GradleKit
import Logging
import MobileCore
import SwiftyShell

/// A Gradle project to build.
public struct GradleProject: Sendable, Equatable {
    /// The directory holding `settings.gradle[.kts]`.
    public var directory: String
    /// `gradlew` to use; `<directory>/gradlew` when it exists, else `gradle` on `PATH`.
    public var gradlewPath: String?
    /// Environment for the Gradle process, e.g. a `JAVA_HOME` from `JavaRuntimes`.
    public var environment: [String: String]
    /// Flags applied to every invocation, e.g. `--no-daemon` on CI.
    public var flags: [GradleFlag]
    /// `-P` properties applied to every invocation.
    public var properties: [String: String]

    public init(
        directory: String,
        gradlewPath: String? = nil,
        environment: [String: String] = [:],
        flags: [GradleFlag] = [],
        properties: [String: String] = [:]
    ) {
        self.directory = directory
        self.gradlewPath = gradlewPath
        self.environment = environment
        self.flags = flags
        self.properties = properties
    }
}

/// Builds Android (and other Gradle) projects, reporting the APKs and bundles Gradle itself
/// recorded (`output-metadata.json`, `build/outputs/bundle`) rather than scraping the log.
public struct GradleBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let logger = Logger.forType(GradleBuilder.self)

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// The `gradle` invocation for `project`, before tasks are added.
    public func command(for project: GradleProject) -> Gradle {
        var gradle = Gradle(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .projectDir(project.directory)
            .settingGradlewPath(project.gradlewPath)
            .flags(project.flags)
        for (key, value) in project.properties.sorted(by: { $0.key < $1.key }) {
            gradle = gradle.property(.custom(key: key, value: value))
        }
        if !project.environment.isEmpty { gradle = gradle.env(project.environment) }
        return gradle
    }

    /// Runs `tasks` and reports every APK, test APK, and bundle written under `modules`'
    /// `build/outputs` during the run.
    ///
    /// - Parameter modules: Module directories relative to the project (`app`); every
    ///   first-level directory with `build/outputs` when empty.
    public func run(
        _ tasks: [GradleTask],
        in project: GradleProject,
        modules: [String] = [],
        clean: Bool = false
    ) async throws -> BuildOutcome {
        logger.info("Gradle build", metadata: ["tasks": "\(tasks.map(\.name))", "project": "\(project.directory)"])
        let started = Date()
        let family = command(for: project).tasks((clean ? [.clean] : []) + tasks)
        let (log, duration) = try await runBuild(family, backend: .gradle) { GradleLogSummary.parse($0).resultLine }
        let artifacts = Self.outputs(projectDirectory: project.directory, modules: modules, modifiedSince: started)
        let summary = GradleLogSummary.parse(log.stdout)
        logger.info("Gradle build finished", metadata: ["result": "\(summary.resultLine ?? "")", "artifacts": "\(artifacts.count)"])
        return BuildOutcome(
            backend: .gradle, artifacts: artifacts, warnings: summary.warningCount, resultLine: summary.resultLine,
            durationSeconds: duration, output: log)
    }

    /// `assemble<Flavor><Variant>` for `module`, optionally with its instrumentation APK.
    public func assemble(
        module: String,
        variant: String = "debug",
        flavor: String? = nil,
        includeAndroidTest: Bool = false,
        in project: GradleProject,
        clean: Bool = false
    ) async throws -> BuildOutcome {
        var tasks = [GradleTask.variantTask(prefix: "assemble", flavor: flavor, variant: variant).qualified(module: module)]
        if includeAndroidTest {
            tasks.append(
                GradleTask.variantTask(prefix: "assemble", flavor: flavor, variant: variant, suffix: "AndroidTest").qualified(
                    module: module))
        }
        return try await run(tasks, in: project, modules: [module], clean: clean)
    }

    /// `bundle<Flavor><Variant>` for `module`, producing an `.aab`.
    public func bundle(
        module: String,
        variant: String = "release",
        flavor: String? = nil,
        in project: GradleProject,
        clean: Bool = false
    ) async throws -> BuildOutcome {
        try await run(
            [GradleTask.variantTask(prefix: "bundle", flavor: flavor, variant: variant).qualified(module: module)], in: project,
            modules: [module], clean: clean)
    }

    // MARK: - Outputs

    /// APKs listed in `output-metadata.json` and `.aab` files under each module's `build/outputs`.
    static func outputs(projectDirectory: String, modules: [String], modifiedSince date: Date) -> [BuildArtifact] {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: projectDirectory)
        let moduleDirectories =
            modules.isEmpty
            ? ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted().map { root.appendingPathComponent($0) }
            : modules.map { root.appendingPathComponent($0.replacingOccurrences(of: ":", with: "/")) }
        var artifacts: [BuildArtifact] = []
        for module in moduleDirectories {
            let outputs = module.appendingPathComponent("build/outputs")
            guard let files = fileManager.enumerator(at: outputs, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }
            for case let file as URL in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard (modified ?? .distantFuture) >= date.addingTimeInterval(-1) else { continue }
                if file.lastPathComponent == "output-metadata.json" {
                    let isTest = file.path.contains("/androidTest/")
                    for apk in apkPaths(fromMetadata: file) {
                        artifacts.append(BuildArtifact(kind: isTest ? .testAPK : .apk, path: apk))
                    }
                } else if file.pathExtension == "aab" {
                    artifacts.append(BuildArtifact(kind: .aab, path: file.path))
                }
            }
        }
        return Array(Set(artifacts)).sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
    }

    /// `elements[].outputFile`, resolved next to the metadata file.
    static func apkPaths(fromMetadata url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let elements = object["elements"] as? [[String: Any]]
        else { return [] }
        return elements.compactMap { $0["outputFile"] as? String }.map {
            url.deletingLastPathComponent().appendingPathComponent($0).path
        }
    }
}
