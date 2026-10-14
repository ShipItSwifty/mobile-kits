import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import Testing

@testable import MobileDevices

/// Records every command a `MockExecutor` runs.
private final class CommandLog: Sendable {
    private let entries = Mutex<[[String]]>([])

    func append(_ arguments: [String]) { entries.withLock { $0.append(arguments) } }
    var all: [[String]] { entries.withLock { $0 } }
}

private func manager(
    log: CommandLog,
    handler: @escaping @Sendable (Command) -> ShellOutput = { _ in ShellOutput(exitCode: 0) }
) -> SimulatorManager {
    SimulatorManager(
        shell: ShellContext(
            executor: MockExecutor { command, _ in
                log.append([command.executableName] + command.arguments)
                return handler(command)
            }))
}

@Suite("SimulatorManager configuration")
struct SimulatorConfigurationTests {
    @Test("Privacy builds grant, revoke, and reset argv")
    func privacy() async throws {
        let log = CommandLog()
        let simulators = manager(log: log)
        try await simulators.privacy(.grant, service: "camera", bundleID: "com.example.app", on: "U")
        try await simulators.privacy(.revoke, service: "photos", bundleID: "com.example.app", on: "U")
        try await simulators.privacy(.reset, service: "all", on: "U")
        #expect(
            log.all == [
                ["xcrun", "simctl", "privacy", "U", "grant", "camera", "com.example.app"],
                ["xcrun", "simctl", "privacy", "U", "revoke", "photos", "com.example.app"],
                ["xcrun", "simctl", "privacy", "U", "reset", "all"],
            ])
    }

    @Test("Location set and clear")
    func location() async throws {
        let log = CommandLog()
        let simulators = manager(log: log)
        try await simulators.setLocation(latitude: 37.5, longitude: -122.25, on: "U")
        try await simulators.clearLocation(on: "U")
        #expect(log.all == [["xcrun", "simctl", "location", "U", "set", "37.5,-122.25"], ["xcrun", "simctl", "location", "U", "clear"]])
    }

    @Test("Appearance and openurl")
    func appearanceAndURL() async throws {
        let log = CommandLog()
        let simulators = manager(log: log)
        try await simulators.setAppearance(.dark, on: "U")
        try await simulators.openURL("myapp://home?x=1", on: "U")
        #expect(log.all == [["xcrun", "simctl", "ui", "U", "appearance", "dark"], ["xcrun", "simctl", "openurl", "U", "myapp://home?x=1"]])
    }

    @Test("A failing simctl call surfaces as a command failure")
    func failure() async {
        let simulators = manager(log: CommandLog()) { _ in ShellOutput(stderr: "Invalid device: U", exitCode: 148) }
        await #expect(
            throws: MobileKitError.commandFailed(
                command: ["xcrun", "simctl", "location", "U", "clear"], exitCode: 148, output: "Invalid device: U")
        ) {
            try await simulators.clearLocation(on: "U")
        }
    }

    static let oldStylePlist = """
        {
            "com.apple.mobilesafari" =     {
                CFBundleDisplayName = Safari;
            };
            "com.example.app" =     {
                CFBundleDisplayName = Example;
            };
        }
        """

    static let xmlPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>com.b</key><dict/><key>com.a</key><dict/>
        </dict></plist>
        """

    @Test("listapps plists (old-style and XML) parse to sorted bundle ids")
    func parsesListApps() {
        #expect(SimulatorManager.bundleIdentifiers(fromListApps: Self.oldStylePlist) == ["com.apple.mobilesafari", "com.example.app"])
        #expect(SimulatorManager.bundleIdentifiers(fromListApps: Self.xmlPlist) == ["com.a", "com.b"])
    }

    @Test("Unparsable listapps output yields no apps")
    func unparsableListApps() {
        #expect(SimulatorManager.bundleIdentifiers(fromListApps: "").isEmpty)
        #expect(SimulatorManager.bundleIdentifiers(fromListApps: "not a plist at all <<<").isEmpty)
        #expect(SimulatorManager.bundleIdentifiers(fromListApps: "(a, b)").isEmpty)
    }

    @Test("installedAppBundleIDs runs listapps and parses stdout")
    func installedApps() async throws {
        let log = CommandLog()
        let simulators = manager(log: log) { _ in ShellOutput(stdout: Self.xmlPlist, exitCode: 0) }
        #expect(try await simulators.installedAppBundleIDs(on: "U") == ["com.a", "com.b"])
        #expect(try await simulators.listApps(on: "U") == Self.xmlPlist)
        #expect(log.all.first == ["xcrun", "simctl", "listapps", "U"])
    }
}

@Suite("SimulatorManager capture", .serialized)
struct SimulatorCaptureTests {
    @Test("Screenshot passes the type and a temp path, returns the bytes, and cleans up")
    func screenshot() async throws {
        let log = CommandLog()
        let written = Mutex<String?>(nil)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let simulators = manager(log: log) { command in
            if let path = command.arguments.last {
                written.withLock { $0 = path }
                try? bytes.write(to: URL(fileURLWithPath: path))
            }
            return ShellOutput(exitCode: 0)
        }
        let data = try await simulators.screenshot("U", format: .jpeg)
        #expect(data == bytes)
        let argv = try #require(log.all.first)
        #expect(Array(argv.prefix(6)) == ["xcrun", "simctl", "io", "U", "screenshot", "--type=jpeg"])
        let path = try #require(written.withLock { $0 })
        #expect(path.hasSuffix(".jpeg"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("A screenshot that wrote nothing is an unexpected-output error")
    func screenshotMissingFile() async {
        let simulators = manager(log: CommandLog())
        await #expect(throws: MobileKitError.self) { try await simulators.screenshot("U") }
    }

    @Test("Recording spawns recordVideo and tracks the process until stopped")
    func recordingLifecycle() async throws {
        let log = CommandLog()
        let simulators = manager(log: log)
        // MockExecutor hands out processes with pid 1.
        let pid = try await simulators.startRecording(on: "U", to: "/tmp/out.mp4")
        #expect(log.all == [["xcrun", "simctl", "io", "U", "recordVideo", "--codec=h264", "--force", "/tmp/out.mp4"]])
        #expect(await simulators.isRecording(pid: pid))
        try await simulators.stopRecording(pid: pid)
        #expect(await !simulators.isRecording(pid: pid))
    }

    @Test("Stopping a tracked recording sends SIGINT and forgets it")
    func stopSendsInterrupt() async throws {
        let process = MockSpawnedProcess(processIdentifier: 424_201)
        await SimulatorRecordingRegistry.shared.register(process)
        let log = CommandLog()
        let simulators = manager(log: log)
        try await simulators.stopRecording(pid: 424_201)
        #expect(await process.signalHistory == [.interrupt])
        #expect(await !simulators.isRecording(pid: 424_201))
        #expect(log.all.isEmpty, "A tracked recording must not shell out to kill")
    }

    @Test("Stopping an untracked pid falls back to kill -INT")
    func stopUntracked() async throws {
        let log = CommandLog()
        try await manager(log: log).stopRecording(pid: 424_202)
        #expect(log.all == [["kill", "-INT", "424202"]])
    }
}
