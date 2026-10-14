import Foundation
import MobileCore
import TestCommons
import Testing

@testable import MobileProject

@Suite("RepositoryInspector")
struct RepositoryInspectorTests {
    func write(_ files: [String: String], in scratch: TemporaryDirectory) throws {
        for (path, text) in files {
            let url = scratch.url.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    @Test("A React Native app with native projects reports every fact, read-only")
    func reactNative() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try write(
            [
                "package.json": #"{"dependencies": {"react-native": "0.85.3"}}"#,
                "ios/App.xcodeproj/project.pbxproj": "", "ios/App.xcworkspace/contents.xcworkspacedata": "",
                "ios/App.xctestplan": "{}", "ios/AppUITests/LoginTests.swift": "",
                "android/settings.gradle": "include ':app'\n",
                "android/app/build.gradle":
                    "apply plugin: \"com.android.application\"\nandroid { namespace \"com.app\"\n defaultConfig { applicationId \"com.app.prod\" } }",
                "node_modules/react-native/package.json": #"{"dependencies": {"react-native": "x"}}"#,
            ], in: scratch)
        let inspection = RepositoryInspector().inspect(scratch.url.path)
        #expect(inspection.frameworks.map(\.value) == [.reactNative])
        #expect(inspection.primaryFramework == .reactNative)
        #expect(Set(inspection.backends.map(\.value)) == [.gradle, .reactNative, .xcodebuild])
        #expect(inspection.xcodeProjects == ["ios/App.xcodeproj"])
        #expect(inspection.xcodeWorkspaces == ["ios/App.xcworkspace"])
        #expect(inspection.testPlans == ["ios/App.xctestplan"])
        #expect(inspection.testDirectories == ["ios/AppUITests"])
        let module = try #require(inspection.gradleModules.first)
        #expect(module.path == ":app")
        #expect(module.directory == "android/app")
        #expect(module.appliesAndroidApplication)
        #expect(module.namespace == "com.app")
        #expect(module.applicationID == "com.app.prod")
        #expect(module.testApplicationID == "com.app.prod.test")
    }

    @Test("Flutter, KMP through a version catalog, Bazel, and Tuist are all recognized")
    func otherStacks() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try write(
            [
                "flutter_app/pubspec.yaml": "name: x\nflutter:\n  uses-material-design: true\n",
                "kmp/gradle/libs.versions.toml": "[plugins]\nkotlinMultiplatform = { id = \"org.jetbrains.kotlin.multiplatform\" }\n",
                "kmp/settings.gradle.kts": "include(\":shared\", \":androidApp\")\n",
                "MODULE.bazel": "", "tuist_app/Project.swift": "", "tuist_app/Tuist/Package.swift": "",
                "pkg/Package.swift": "// swift-tools-version: 6.2",
            ], in: scratch)
        let inspection = RepositoryInspector().inspect(scratch.url.path)
        #expect(Set(inspection.frameworks.map(\.value)) == [.flutter, .kmp])
        #expect(inspection.primaryFramework == .flutter)
        #expect(inspection.frameworks.first { $0.value == .kmp }?.evidence.first?.line == 2)
        #expect(Set(inspection.backends.map(\.value)).isSuperset(of: [.bazel, .flutter, .gradle, .swiftPM]))
        #expect(inspection.swiftPackages == ["pkg"], "Tuist/Package.swift is Tuist's dependency manifest")
        #expect(Set(inspection.projectGenerators.map(\.value)) == ["tuist"])
        #expect(inspection.gradleModules.map(\.path) == [":shared", ":androidApp"])
    }

    @Test("A plain native project is native")
    func native() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try write(["App.xcodeproj/project.pbxproj": ""], in: scratch)
        #expect(RepositoryInspector().inspect(scratch.url.path).primaryFramework == .native)
    }
}

@Suite("FrameworkDetector")
struct FrameworkDetectorTests {
    @Test("Root and first-level modules decide; a nested example app does not")
    func precedence() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let root = scratch.url
        func write(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        #expect(FrameworkDetector.detect(in: root.path) == nil)
        try write("examples/rn/package.json", #"{"dependencies": {"react-native": "1"}}"#)
        #expect(FrameworkDetector.detect(in: root.path) == nil, "two levels down is not this app")
        try write("shared/build.gradle.kts", #"plugins { kotlin("multiplatform") }"#)
        #expect(FrameworkDetector.detect(in: root.path) == .kmp)
        try write("package.json", #"{"devDependencies": {"react-native": "1"}}"#)
        #expect(FrameworkDetector.detect(in: root.path) == .reactNative)
        try write("pubspec.yaml", "name: a\nflutter:\n")
        #expect(FrameworkDetector.detect(in: root.path) == .flutter)
    }
}
