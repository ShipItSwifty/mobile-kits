import Foundation
import GradleKit
import SwiftyShell
import TestCommons
import Testing

@testable import MobileBuild

@Suite("Cached Gradle artifacts")
struct GradleCachedOutputTests {
    @Test("An up-to-date build preserves custom paths and selects only the requested variant", arguments: [false, true])
    func cachedOutputs(bundle: Bool) async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let root = scratch.url
        for variant in ["freeDebug", "paidRelease"] {
            let directory = root.appending(path: "app/build/outputs/\(bundle ? "bundle" : "apk")/\(variant)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let artifact = directory.appending(path: "custom-\(variant).\(bundle ? "aab" : "apk")")
            try Data().write(to: artifact)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: artifact.path)
            if !bundle {
                let metadata = directory.appending(path: "output-metadata.json")
                try Data("{\"variantName\":\"\(variant)\",\"elements\":[{\"outputFile\":\"\(artifact.lastPathComponent)\"}]}".utf8).write(
                    to: metadata)
                try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: metadata.path)
            }
        }
        let shell = ShellContext(executor: MockExecutor(stdout: "> Task :app:assembleFreeDebug UP-TO-DATE\nBUILD SUCCESSFUL\n"))
        let task = bundle ? GradleTask.bundle(variant: "freeDebug") : .assemble(variant: "freeDebug")
        let outcome = try await GradleBuilder(shell: shell).run(
            [task.qualified(module: "app")], in: GradleProject(directory: root.path), modules: ["app"])
        #expect(outcome.artifacts.count == 1)
        #expect(outcome.artifacts.first?.path.hasSuffix("custom-freeDebug.\(bundle ? "aab" : "apk")") == true)
    }
    @Test("Cached instrumentation metadata uses the AndroidTest variant suffix", arguments: [false, true])
    func instrumentationVariant(includeTests: Bool) async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for path in ["apk/free/debug", "apk/androidTest/free/debug"] {
            let directory = scratch.url.appending(path: "app/build/outputs/\(path)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let variant = path.contains("androidTest") ? "freeDebugAndroidTest" : "freeDebug"
            let metadata = directory.appending(path: "output-metadata.json")
            try Data("{\"variantName\":\"\(variant)\",\"elements\":[{\"outputFile\":\"custom.apk\"}]}".utf8).write(to: metadata)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: metadata.path)
        }
        let outcome = try await GradleBuilder(shell: ShellContext(executor: MockExecutor()))
            .assemble(
                module: "app", variant: "debug", flavor: "free", includeAndroidTest: includeTests,
                in: GradleProject(directory: scratch.url.path))
        #expect(outcome.artifacts.map(\.kind) == (includeTests ? [.apk, .testAPK] : [.apk]))
    }

}

@Suite("Gradle output selection metadata")
struct GradleOutputSelectionMetadataTests {
    @Test("Supplied metadata decides the variant without reading the file again")
    func usesSuppliedMetadata() {
        let file = URL(fileURLWithPath: "/nonexistent/app/build/outputs/apk/free/debug/output-metadata.json")
        let selection = GradleOutputSelection(
            tasks: [GradleTask.custom(":app:assembleFreeDebug")], module: "/nonexistent/app", root: "/nonexistent")
        #expect(selection.includes(file, fresh: false, metadata: ["variantName": "freeDebug"]))
        #expect(!selection.includes(file, fresh: false, metadata: ["variantName": "paidRelease"]))
    }

    @Test("APK paths resolve next to the metadata file from parsed content")
    func apkPathsFromParsedMetadata() {
        let url = URL(fileURLWithPath: "/p/app/build/outputs/apk/debug/output-metadata.json")
        let paths = GradleBuilder.apkPaths(in: ["elements": [["outputFile": "app-debug.apk"]]], next: url)
        #expect(paths == ["/p/app/build/outputs/apk/debug/app-debug.apk"])
        #expect(GradleBuilder.apkPaths(in: nil, next: url).isEmpty)
    }
}
