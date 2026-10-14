import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import TestCommons
import Testing
import XcodeBuildKit

@testable import MobileBuild

@Suite("XcodeBuilder")
struct XcodeBuilderTests {
    @Test("Request maps to one xcodebuild invocation with sorted build settings")
    func command() {
        let request = XcodeBuildRequest(
            container: .workspace("ios/App.xcworkspace"), scheme: "App", configuration: "Debug", destination: .anyIOSSimulator,
            derivedDataPath: "DD", buildSettings: ["B": "2", "A": "1"], additionalOptions: [.allowProvisioningUpdates])
        let arguments = XcodeBuilder().command(for: request).build().command().arguments
        #expect(arguments.starts(with: ["-workspace", "ios/App.xcworkspace"]))
        #expect(arguments.contains("generic/platform=iOS Simulator"))
        #expect(arguments.contains("-allowProvisioningUpdates"))
        #expect(arguments.firstIndex(of: "A=1")! < arguments.firstIndex(of: "B=2")!)
        #expect(arguments.last == "build")
    }

    @Test("Products come from -showBuildSettings, not the log")
    func parsesBuildSettings() throws {
        let targets = try XcodeTargetSettings.parse(
            """
            Command line invocation: …
            [{"action": "build", "target": "App", "buildSettings": {
               "WRAPPER_EXTENSION": "app", "TARGET_BUILD_DIR": "/DD/Build/Products/Debug-iphonesimulator",
               "FULL_PRODUCT_NAME": "App.app", "DWARF_DSYM_FOLDER_PATH": "/DD/Build/Products/Debug-iphonesimulator",
               "DWARF_DSYM_FILE_NAME": "App.app.dSYM", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app", "SYMROOT": "/DD/Build/Products"}},
             {"action": "build", "target": "AppKit", "buildSettings": {"WRAPPER_EXTENSION": "framework", "TARGET_BUILD_DIR": "/x"}}]
            """)
        #expect(targets.count == 2)
        #expect(targets[0].applicationPath == "/DD/Build/Products/Debug-iphonesimulator/App.app")
        #expect(targets[0].dsymPath == "/DD/Build/Products/Debug-iphonesimulator/App.app.dSYM")
        #expect(targets[0].bundleIdentifier == "com.example.app")
        #expect(targets[1].applicationPath == nil)
    }

    @Test("A failed build carries the exit code and the result line")
    func failure() async {
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "x.swift:1:1: error: nope\n** BUILD FAILED **\n", exitCode: 65) }
        await #expect(throws: BuildFailure.self) {
            try await XcodeBuilder(shell: ShellContext(executor: executor)).build(XcodeBuildRequest(scheme: "App"))
        }
        do {
            _ = try await XcodeBuilder(shell: ShellContext(executor: executor)).build(XcodeBuildRequest(scheme: "App"))
        } catch let failure as BuildFailure {
            #expect(failure.exitCode == 65)
            #expect(failure.summary == "** BUILD FAILED **")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Export options serialize to a plist")
    func exportOptions() throws {
        let data = try ExportOptions(method: "app-store-connect", teamID: "T", provisioningProfiles: ["com.x": "P"]).plistData()
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["method"] as? String == "app-store-connect")
        #expect(plist["teamID"] as? String == "T")
        #expect((plist["provisioningProfiles"] as? [String: String])?["com.x"] == "P")
    }
}

@Suite("XcodeBuilder test products and export")
struct XcodeBuilderTestProductsTests {
    @Test("build-for-testing writes one .xctestproducts bundle and reads no build settings")
    func buildForTestingTestProducts() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let products = scratch.url.appendingPathComponent("App.xctestproducts").path
        let seen = Mutex([[String]]())
        let executor = MockExecutor { command, _ in
            seen.withLock { $0.append(command.arguments) }
            try FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: true)
            return ShellOutput(stdout: "** TEST BUILD SUCCEEDED **\n", stderr: "", exitCode: 0)
        }
        let outcome = try await XcodeBuilder(shell: ShellContext(executor: executor))
            .buildForTesting(XcodeBuildRequest(scheme: "App"), testProductsPath: products)

        let calls = seen.withLock { $0 }
        #expect(calls.count == 1, "No -showBuildSettings run")
        #expect(calls[0].contains("build-for-testing"))
        #expect(zip(calls[0], calls[0].dropFirst()).contains { $0 == "-testProductsPath" && $1 == products })
        #expect(outcome.artifacts == [BuildArtifact(kind: .xctestproducts, path: products)])
    }

    @Test("export passes additional options such as -allowProvisioningUpdates")
    func exportAdditionalOptions() async throws {
        let seen = Mutex([String]())
        let executor = MockExecutor { command, _ in
            seen.withLock { $0 = command.arguments }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        _ = try await XcodeBuilder(shell: ShellContext(executor: executor))
            .exportArchive(
                archivePath: "/tmp/A.xcarchive", exportPath: "/tmp/does-not-exist-export", options: ExportOptions(method: "app-store"),
                additionalOptions: [.allowProvisioningUpdates])
        #expect(seen.withLock { $0 }.contains("-allowProvisioningUpdates"))
        #expect(seen.withLock { $0 }.contains("-exportArchive"))
    }
}

@Suite("GradleBuilder")
struct GradleBuilderTests {
    @Test("APKs come from output-metadata.json; bundles from build/outputs/bundle")
    func outputs() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let apkDirectory = scratch.url.appending(path: "app/build/outputs/apk/debug")
        let testDirectory = scratch.url.appending(path: "app/build/outputs/apk/androidTest/debug")
        let bundleDirectory = scratch.url.appending(path: "app/build/outputs/bundle/release")
        for directory in [apkDirectory, testDirectory, bundleDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(#"{"elements": [{"outputFile": "app-debug.apk"}]}"#.utf8).write(to: apkDirectory.appending(path: "output-metadata.json"))
        try Data(#"{"elements": [{"outputFile": "app-debug-androidTest.apk"}]}"#.utf8)
            .write(to: testDirectory.appending(path: "output-metadata.json"))
        try Data().write(to: bundleDirectory.appending(path: "app-release.aab"))
        let artifacts = GradleBuilder.outputs(projectDirectory: scratch.url.path, modules: ["app"], modifiedSince: .distantPast)
        #expect(artifacts.map(\.kind) == [.aab, .apk, .testAPK])
        #expect(artifacts[1].path.hasSuffix("app/build/outputs/apk/debug/app-debug.apk"))
    }

    @Test("Assemble qualifies tasks with the module and adds the androidTest APK on request")
    func assembleTasks() async throws {
        let seen = Mutex<[String]>([])
        let executor = MockExecutor { command, _ in
            seen.withLock { $0 = command.arguments }
            return ShellOutput(stdout: "BUILD SUCCESSFUL in 3s\n", exitCode: 0)
        }
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let outcome = try await GradleBuilder(shell: ShellContext(executor: executor))
            .assemble(
                module: "app", variant: "debug", flavor: "free", includeAndroidTest: true, in: GradleProject(directory: scratch.url.path))
        #expect(seen.withLock { $0 }.suffix(2) == [":app:assembleFreeDebug", ":app:assembleFreeDebugAndroidTest"])
        #expect(outcome.resultLine == "BUILD SUCCESSFUL in 3s")
    }
}

@Suite("Framework builders")
struct FrameworkBuilderTests {
    @Test("Flutter products come from its ✓ Built lines")
    func flutterBuilt() {
        let artifacts = FlutterBuilder.builtArtifacts(
            in:
                "Running Gradle task 'assembleRelease'...\n✓ Built build/app/outputs/flutter-apk/app-release.apk (21.1MB)\n✓ Built build/ios/iphonesimulator/Runner.app.\n",
            relativeTo: "/p")
        #expect(
            artifacts == [
                BuildArtifact(kind: .apk, path: "/p/build/app/outputs/flutter-apk/app-release.apk"),
                BuildArtifact(kind: .app, path: "/p/build/ios/iphonesimulator/Runner.app"),
            ])
    }

    @Test("Bazel outputs and test results come from the build event stream")
    func buildEventStream() {
        let stream = BuildEventStream.parse(
            """
            {"id": {"namedSet": {"id": "1"}}, "namedSetOfFiles": {"files": [{"name": "app.ipa", "uri": "file:///out/app.ipa"}]}}
            {"id": {"namedSet": {"id": "0"}}, "namedSetOfFiles": {"files": [{"name": "app.dSYM", "uri": "file:///out/app.dSYM"}], "fileSets": [{"id": "1"}]}}
            {"id": {"targetCompleted": {"label": "//app:app"}}, "completed": {"success": true, "outputGroup": [{"name": "default", "fileSets": [{"id": "0"}]}]}}
            {"id": {"testResult": {"label": "//app:tests", "run": 1, "shard": 1, "attempt": 2}}, "testResult": {"status": "PASSED", "testAttemptDurationMillis": "1500", "testActionOutput": [{"name": "test.xml", "uri": "file:///out/test.xml"}, {"name": "test.log", "uri": "file:///out/test.log"}]}}
            not json
            """)
        #expect(stream.targets == [.init(label: "//app:app", success: true, files: ["/out/app.dSYM", "/out/app.ipa"])])
        #expect(stream.tests.first?.junitFiles == ["/out/test.xml"])
        #expect(stream.tests.first?.attempt == 2)
        #expect(stream.tests.first?.durationMillis == 1500)
    }

    @Test("Log summaries")
    func summaries() {
        let xcode = XcodeBuildLogSummary.parse("a.swift:1:2: warning: w\nb.swift:3:4: error: e\n** BUILD FAILED **\n")
        #expect(xcode == XcodeBuildLogSummary(resultLine: "** BUILD FAILED **", warningCount: 1, errorCount: 1))
        let gradle = GradleLogSummary.parse(
            "w: A.kt:1 unused\nBUILD SUCCESSFUL in 9s\n12 actionable tasks: 3 executed\nhttps://gradle.com/s/abc\n")
        #expect(gradle.resultLine == "BUILD SUCCESSFUL in 9s")
        #expect(gradle.actionableTasksLine == "12 actionable tasks: 3 executed")
        #expect(gradle.buildScanURL == "https://gradle.com/s/abc")
        #expect(gradle.warningCount == 1)
    }
}
