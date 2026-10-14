import CocoaPodsKit
import FlutterKit
import Foundation
import GradleKit
import Logging
import MobileCore
import ReactNativeKit
import SwiftyShell

// MARK: - Flutter

/// Builds Flutter apps. Products come from Flutter's own `✓ Built <path>` lines.
public struct FlutterBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let executable: (path: String, prefix: [String])
    private let logger = Logger.forType(FlutterBuilder.self)

    /// - Parameter executable: `("flutter", [])`, or `("fvm", ["flutter"])` for FVM-managed SDKs.
    public init(
        shell: ShellContext = .init(), output: BuildOutput = .init(), executable: (path: String, prefix: [String]) = ("flutter", [])
    ) {
        self.shell = shell
        self.output = output
        self.executable = executable
    }

    private func flutter(in directory: String) -> Flutter {
        Flutter(context: shell, executablePath: executable.path, prefix: executable.prefix)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
            .workingDirectory(directory)
    }

    /// `flutter pub get`.
    public func fetchDependencies(in directory: String, enforceLockfile: Bool = false) async throws {
        try await ToolRunner.run(flutter(in: directory).pubGet(enforceLockfile: enforceLockfile), timeout: .seconds(600))
    }

    /// `flutter build <target>`.
    public func build(
        _ target: FlutterBuildTarget,
        in directory: String,
        mode: FlutterBuildMode = .release,
        simulator: Bool = false,
        codesign: Bool? = nil,
        flavor: String? = nil,
        dartDefines: [String: String] = [:],
        entryPoint: String? = nil,
        buildName: String? = nil,
        buildNumber: String? = nil,
        exportOptionsPlist: String? = nil
    ) async throws -> BuildOutcome {
        logger.info("flutter build", metadata: ["target": "\(target.rawValue)", "mode": "\(mode.rawValue)"])
        let family = flutter(in: directory).build(
            target, mode: mode, simulator: simulator, codesign: codesign, flavor: flavor, dartDefines: dartDefines,
            entryPoint: entryPoint, buildName: buildName, buildNumber: buildNumber, exportOptionsPlist: exportOptionsPlist)
        let (log, duration) = try await runBuild(family, backend: .flutter)
        let artifacts = Self.builtArtifacts(in: log.stdout + "\n" + log.stderr, relativeTo: directory)
        return BuildOutcome(
            backend: .flutter, artifacts: artifacts, durationSeconds: duration, output: log,
            diagnostics: artifacts.isEmpty ? ["flutter build reported no built artifact"] : [])
    }

    /// Parses `✓ Built build/app/outputs/flutter-apk/app-release.apk (21.1MB)` lines.
    static func builtArtifacts(in log: String, relativeTo directory: String) -> [BuildArtifact] {
        log.split(whereSeparator: \.isNewline).compactMap { line -> BuildArtifact? in
            guard let range = line.range(of: "Built ") else { return nil }
            var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let size = path.range(of: " (", options: .backwards) { path = String(path[..<size.lowerBound]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let absolute = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
            return artifactKind(for: absolute).map { BuildArtifact(kind: $0, path: absolute) }
        }
    }
}

/// The artifact kind a path's extension implies.
func artifactKind(for path: String) -> BuildArtifact.Kind? {
    switch (path as NSString).pathExtension.lowercased() {
    case "app": .app
    case "ipa": .ipa
    case "xcarchive": .xcarchive
    case "apk": path.contains("androidTest") || path.hasSuffix("-androidTest.apk") ? .testAPK : .apk
    case "aab": .aab
    case "dsym": .dsym
    case "framework": .framework
    case "xcframework": .xcframework
    case "xctestrun": .xctestrun
    case "jsbundle", "bundle": .jsBundle
    default: nil
    }
}

// MARK: - React Native

/// Builds React Native apps the way their native projects expect: CocoaPods then `xcodebuild`
/// for iOS, Gradle for Android. Debug builds load JavaScript from Metro (``ReactNativeBuilder/startMetro(in:port:)``);
/// release builds embed the bundle through their own build phases.
public struct ReactNativeBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let runner: JSPackageRunner
    private let logger = Logger.forType(ReactNativeBuilder.self)

    public init(shell: ShellContext = .init(), output: BuildOutput = .init(), runner: JSPackageRunner = .npx) {
        self.shell = shell
        self.output = output
        self.runner = runner
    }

    /// Runs `expo prebuild` when the project has no `ios/` or `android/` directory yet.
    public func prebuildIfNeeded(in directory: String, platform: MobilePlatform) async throws {
        let native = (directory as NSString).appendingPathComponent(platform == .ios ? "ios" : "android")
        guard !FileManager.default.fileExists(atPath: native) else { return }
        logger.info("Generating native project with expo prebuild", metadata: ["platform": "\(platform.rawValue)"])
        try await ToolRunner.run(
            Expo(context: shell, runner: runner).prebuild(platform: platform.rawValue).workingDirectory(directory),
            timeout: .seconds(900))
    }

    /// `pod install` in `<directory>/ios`, through Bundler when the project has a `Gemfile`.
    public func installPods(in directory: String, deployment: Bool = false) async throws {
        let ios = (directory as NSString).appendingPathComponent("ios")
        let bundler =
            FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent("Gemfile"))
            || FileManager.default.fileExists(atPath: (ios as NSString).appendingPathComponent("Gemfile"))
        logger.info("pod install", metadata: ["directory": "\(ios)", "bundler": "\(bundler)"])
        try await ToolRunner.run(
            Pod(context: shell, bundler: bundler).install(deployment: deployment).workingDirectory(ios), timeout: .seconds(1200))
    }

    /// Builds the iOS app: `pod install` (when a `Podfile` exists), then `xcodebuild` of
    /// `ios/<workspace>`. `request.container` defaults to the only workspace in `ios/`.
    public func buildIOS(_ request: XcodeBuildRequest, in directory: String, installPods: Bool = true) async throws -> BuildOutcome {
        let ios = (directory as NSString).appendingPathComponent("ios")
        if installPods, FileManager.default.fileExists(atPath: (ios as NSString).appendingPathComponent("Podfile")) {
            try await self.installPods(in: directory)
        }
        var resolved = request
        if resolved.container == nil {
            let workspaces = ((try? FileManager.default.contentsOfDirectory(atPath: ios)) ?? []).filter { $0.hasSuffix(".xcworkspace") }
            guard workspaces.count == 1 else {
                throw MobileKitError.invalidRequest(
                    "Expected one .xcworkspace in \(ios), found \(workspaces.isEmpty ? "none" : workspaces.joined(separator: ", ")); pass container."
                )
            }
            resolved.container = .workspace((ios as NSString).appendingPathComponent(workspaces[0]))
        }
        return try await XcodeBuilder(shell: shell, output: output).build(resolved)
    }

    /// Builds the Android app with Gradle in `<directory>/android`.
    public func buildAndroid(
        in directory: String,
        module: String = "app",
        variant: String = "debug",
        flavor: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> BuildOutcome {
        let android = (directory as NSString).appendingPathComponent("android")
        return try await GradleBuilder(shell: shell, output: output)
            .assemble(module: module, variant: variant, flavor: flavor, in: GradleProject(directory: android, environment: environment))
    }

    /// Writes the offline JavaScript bundle (`react-native bundle`).
    public func bundleJavaScript(
        in directory: String,
        platform: MobilePlatform,
        bundleOutput: String,
        assetsDestination: String? = nil,
        entryFile: String = "index.js"
    ) async throws -> BuildArtifact {
        try await ToolRunner.run(
            ReactNative(context: shell, runner: runner)
                .bundle(platform: platform.rawValue, entryFile: entryFile, bundleOutput: bundleOutput, assetsDestination: assetsDestination)
                .workingDirectory(directory),
            timeout: .seconds(600))
        return BuildArtifact(kind: .jsBundle, path: bundleOutput)
    }

    /// Starts Metro for debug builds. The caller owns the returned process.
    public func startMetro(in directory: String, port: Int = 8081) async throws -> any SpawnedProcess {
        let metro = ReactNative(context: shell, runner: runner).start(port: port).workingDirectory(directory)
        do {
            return try await metro.spawn(teardown: .graceful)
        } catch let error as ShellError {
            throw ToolRunner.map(error, argv: [metro.command().executableName] + metro.command().arguments)
        }
    }
}

// MARK: - Kotlin Multiplatform

/// Builds Kotlin Multiplatform apps: Gradle for the Android app and the shared framework, then
/// the Xcode host project for iOS.
public struct KMPBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// Builds the Android app module.
    public func buildAndroid(
        module: String = "androidApp", variant: String = "debug", in project: GradleProject
    ) async throws
        -> BuildOutcome
    {
        try await GradleBuilder(shell: shell, output: output).assemble(module: module, variant: variant, in: project)
    }

    /// Links the shared module's Apple framework, e.g. `linkDebugFrameworkIosSimulatorArm64` or
    /// `assembleSharedXCFramework`.
    public func buildFramework(module: String = "shared", task: String, in project: GradleProject) async throws -> BuildOutcome {
        var outcome = try await GradleBuilder(shell: shell, output: output)
            .run([GradleTask.custom(task).qualified(module: module)], in: project, modules: [module])
        outcome.artifacts += Self.frameworks(
            inBuildDirectory: URL(fileURLWithPath: project.directory).appendingPathComponent(module).appendingPathComponent("build"))
        return outcome
    }

    /// Kotlin/Native links into `build/bin/<target>/<build type>Framework`; XCFramework tasks
    /// write `build/XCFrameworks`.
    static func frameworks(inBuildDirectory build: URL) -> [BuildArtifact] {
        var artifacts: [BuildArtifact] = []
        for root in ["bin", "XCFrameworks"].map({ build.appendingPathComponent($0) }) {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "framework" || url.pathExtension == "xcframework" {
                files.skipDescendants()
                artifacts.append(BuildArtifact(kind: url.pathExtension == "framework" ? .framework : .xcframework, path: url.path))
            }
        }
        return artifacts.sorted { $0.path < $1.path }
    }

    /// Builds the iOS host app. Its build phase normally invokes Gradle
    /// (`embedAndSignAppleFrameworkForXcode`), so a separate framework build is optional.
    public func buildIOS(_ request: XcodeBuildRequest) async throws -> BuildOutcome {
        try await XcodeBuilder(shell: shell, output: output).build(request)
    }
}
