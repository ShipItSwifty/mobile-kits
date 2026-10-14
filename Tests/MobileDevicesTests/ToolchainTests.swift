import Foundation
import TestCommons
import Testing

@testable import MobileDevices

@Suite("Toolchains")
struct ToolchainTests {
    func makeJDK(_ root: URL, _ name: String, version: String, macOSLayout: Bool) throws {
        let home = macOSLayout ? root.appending(path: "\(name)/Contents/Home") : root.appending(path: name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("JAVA_VERSION=\"\(version)\"\n".utf8).write(to: home.appending(path: "release"))
    }

    @Test("Picks the newest JDK in the caller's range, keeping an in-range JAVA_HOME")
    func resolvesJavaHome() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try makeJDK(scratch.url, "temurin-17.jdk", version: "17.0.9", macOSLayout: true)
        try makeJDK(scratch.url, "temurin-21.jdk", version: "21.0.4", macOSLayout: true)
        try makeJDK(scratch.url, "java-27-openjdk", version: "27", macOSLayout: false)
        try makeJDK(scratch.url, "zulu-8", version: "1.8.0_402", macOSLayout: false)
        let runtimes = JavaRuntimes(searchPaths: [scratch.url.path])
        #expect(Set(runtimes.installed().map(\.majorVersion)) == [8, 17, 21, 27])
        let newest = try #require(runtimes.resolveJavaHome(supported: 17...26, environment: [:]))
        #expect(newest.hasSuffix("temurin-21.jdk/Contents/Home"))
        let pinned = scratch.url.appending(path: "temurin-17.jdk/Contents/Home").path
        #expect(runtimes.resolveJavaHome(supported: 17...26, environment: ["JAVA_HOME": pinned]) == pinned)
        #expect(runtimes.environment(supported: 17...26, base: ["JAVA_HOME": "/nope"])["JAVA_HOME"] == newest)
        #expect(runtimes.resolveJavaHome(supported: 30...31, environment: [:]) == nil)
    }

    @Test("Parses xcodebuild -version")
    func parsesXcodeVersion() {
        let parsed = XcodeToolchain.parseVersion("Xcode 26.4\nBuild version 17E192\n")
        #expect(parsed?.version == "26.4")
        #expect(parsed?.build == "17E192")
        #expect(XcodeToolchain.parseVersion("xcode-select: error") == nil)
    }
}
