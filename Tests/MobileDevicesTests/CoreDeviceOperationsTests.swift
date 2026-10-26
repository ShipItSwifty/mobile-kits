import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import Testing

@testable import MobileDevices

/// The argv of every command a mock executor received.
private final class CommandLog: Sendable {
    private let storage = Mutex<[[String]]>([])

    func record(_ arguments: [String]) {
        storage.withLock { $0.append(arguments) }
    }

    var commands: [[String]] { storage.withLock { $0 } }
}

@Suite("PhysicalIOSDeviceManager CoreDevice operations")
struct CoreDeviceOperationsTests {
    private static let udid = "UDID-1"

    /// A manager whose devicectl answers each command with `respond`, and a log of the argv it saw.
    private func manager(
        _ respond: @escaping @Sendable (Command) throws -> ShellOutput
    ) -> (PhysicalIOSDeviceManager, CommandLog) {
        let log = CommandLog()
        let executor = MockExecutor { command, _ in
            log.record(command.arguments)
            return try respond(command)
        }
        return (PhysicalIOSDeviceManager(shell: ShellContext(executor: executor)), log)
    }

    private func fixture(_ name: String, exitCode: Int32 = 0) throws -> ShellOutput {
        ShellOutput(stdout: try DeviceCtlFixture.text(name), exitCode: exitCode)
    }

    // MARK: - Listing

    @Test("Listing keeps hardware by default and adds simulators on request")
    func listing() async throws {
        let (manager, _) = manager { _ in try fixture("list-devices") }
        #expect(try await manager.list().map(\.name) == ["Test iPhone"])
        #expect(try await manager.list(includeSimulators: true).count == 3)
        #expect(try await manager.list(connectedOnly: true, includeSimulators: true).map(\.udid) == [DeviceCtlFixture.simulator])
        #expect(try await manager.list(platform: "watchOS", includeSimulators: true).isEmpty)
    }

    // MARK: - Launch and processes

    @Test("Launch ends devicectl's options before the app's arguments and returns the process")
    func launch() async throws {
        let (manager, log) = manager { _ in try fixture("process-launch") }
        let process = try await manager.launch(
            bundleID: "com.example", on: Self.udid, arguments: ["-v", "x"], environment: ["K": "V"], payloadURL: "app://x",
            options: .init(activate: false))
        #expect(process.processIdentifier == 63448)
        #expect(
            log.commands == [
                [
                    "devicectl", "device", "process", "launch", "--device", Self.udid, "--no-activate", "--terminate-existing",
                    "--environment-variables", #"{"K":"V"}"#, "--payload-url", "app://x", "--json-output", "-", "--", "com.example",
                    "-v", "x",
                ]
            ])
    }

    @Test("Launch can leave a running instance alone and start suspended")
    func launchOptions() async throws {
        let (manager, log) = manager { _ in try fixture("process-launch") }
        try await manager.launch(bundleID: "b", on: Self.udid, terminateExisting: false, startStopped: true)
        #expect(
            log.commands
                == [["devicectl", "device", "process", "launch", "--device", Self.udid, "--start-stopped", "--json-output", "-", "b"]])
    }

    @Test("A launch with no process in the result is unexpected output")
    func launchWithoutProcess() async {
        let (manager, _) = manager { _ in
            ShellOutput(stdout: #"{"info": {"outcome": "success", "commandType": "x", "jsonVersion": 5}, "result": {}}"#, exitCode: 0)
        }
        await #expect(
            throws: MobileKitError.unexpectedOutput(tool: "devicectl device process launch", detail: "no process identifier in the result")
        ) {
            try await manager.launch(bundleID: "b", on: Self.udid)
        }
    }

    @Test("Terminating by pid can force the kill")
    func terminatePID() async throws {
        let (manager, log) = manager { _ in
            ShellOutput(stdout: #"{"info": {"outcome": "success", "commandType": "x", "jsonVersion": 5}, "result": {}}"#, exitCode: 0)
        }
        try await manager.terminate(pid: 42, on: Self.udid)
        try await manager.terminate(pid: 42, on: Self.udid, force: true)
        let commands = log.commands
        #expect(commands[0] == ["devicectl", "device", "process", "terminate", "--device", Self.udid, "--pid", "42", "--json-output", "-"])
        #expect(
            commands[1] == [
                "devicectl", "device", "process", "terminate", "--device", Self.udid, "--pid", "42", "--kill", "--json-output", "-",
            ])
    }

    @Test("Terminating an app that is not running sends nothing")
    func terminateNotRunning() async throws {
        let (manager, log) = manager { _ in
            ShellOutput(
                stdout: #"{"result": {"runningProcesses": [{"processIdentifier": 1, "executable": "file:///sbin/launchd"}]}}"#, exitCode: 0)
        }
        try await manager.terminate(bundleID: "com.example.Jot", on: Self.udid)
        #expect(log.commands.count == 1)
    }

    // MARK: - Failures

    @Test("A CoreDevice failure is thrown with its code and the command that failed")
    func failure() async throws {
        let (manager, _) = manager { _ in try fixture("failure-unsupported-capability", exitCode: 1) }
        let error = await #expect(throws: MobileKitError.self) { try await manager.lockState(of: Self.udid) }
        guard case .coreDeviceFailed(let failure) = error else {
            Issue.record("expected a CoreDevice failure, got \(String(describing: error))")
            return
        }
        #expect(failure.isUnsupportedCapability)
        #expect(failure.capability == "Get Lock State")
        #expect(failure.command == ["xcrun", "devicectl", "device", "info", "lockState", "--device", Self.udid, "--json-output", "-"])
    }

    @Test("A command that wrote no JSON fails with its output")
    func failureWithoutJSON() async {
        let (manager, _) = manager { _ in ShellOutput(stderr: "xcrun: error: boom", exitCode: 72) }
        await #expect(
            throws: MobileKitError.commandFailed(
                command: ["xcrun", "devicectl", "device", "info", "lockState", "--device", Self.udid, "--json-output", "-"], exitCode: 72,
                output: "xcrun: error: boom")
        ) {
            try await manager.lockState(of: Self.udid)
        }
    }

    // MARK: - Typed reads

    @Test("Typed reads decode the document the command wrote")
    func typedReads() async throws {
        let (manager, log) = manager { command in
            let name =
                [
                    "appearance": "info-appearance", "audio": "info-audio", "displays": "info-displays", "voiceover": "info-voiceover",
                    "standby": "info-standby", "apps": "info-apps", "details": "info-details-simulator", "get": "orientation-get",
                    "pasteboard": "pasteboard-info",
                ]
                .first { command.arguments.contains($0.key) }?.value
            return try fixture(name ?? "info-appearance")
        }
        #expect(try await manager.appearance(of: Self.udid).userInterfaceStyle == "light")
        #expect(try await manager.audio(of: Self.udid).volume == 60)
        #expect(try await manager.displays(on: Self.udid).primary?.nativeWidth == 1320)
        #expect(try await manager.isVoiceOverEnabled(on: Self.udid) == false)
        #expect(try await manager.standbyState(of: Self.udid) == "unavailable")
        #expect(try await manager.apps(on: Self.udid, bundleID: "com.amoo.companion").count == 2)
        #expect(try await manager.details(of: Self.udid).bootState == "booted")
        #expect(try await manager.orientation(of: Self.udid).nonFlatOrientation == "portrait")
        #expect(try await manager.pasteboardInfo(on: Self.udid).changeCount == 162)
        #expect(log.commands.last == ["devicectl", "device", "pasteboard", "info", "--device", Self.udid, "--json-output", "-"])
        #expect(
            log.commands[5] == [
                "devicectl", "device", "info", "apps", "--device", Self.udid, "--bundle-id", "com.amoo.companion", "--json-output", "-",
            ])
    }

    // MARK: - Payloads and files

    @Test("A screenshot is returned as the PNG devicectl wrote and its temporary file is removed")
    func screenshotData() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let written = Mutex<String?>(nil)
        let (manager, _) = manager { command in
            if let index = command.arguments.firstIndex(of: "--destination") {
                let path = command.arguments[index + 1]
                try png.write(to: URL(fileURLWithPath: path))
                written.withLock { $0 = path }
            }
            return try fixture("capture-screenshot")
        }
        let data = try await manager.screenshot(on: Self.udid, displayUniqueID: "DISPLAY")
        #expect(data == png)
        let path = try #require(written.withLock { $0 })
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("A screenshot that devicectl did not write is unexpected output")
    func screenshotMissing() async {
        let (manager, _) = manager { _ in try fixture("capture-screenshot") }
        await #expect(throws: MobileKitError.self) { try await manager.screenshot(on: Self.udid) }
    }

    @Test("Pasteboard data comes back byte for byte, with the JSON in a file so stdout is free")
    func pasteboardBytes() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x80])
        let jsonPath = Mutex<String?>(nil)
        let (manager, log) = manager { command in
            if let index = command.arguments.firstIndex(of: "--json-output") {
                let path = command.arguments[index + 1]
                try Data(try DeviceCtlFixture.text("process-launch").utf8).write(to: URL(fileURLWithPath: path))
                jsonPath.withLock { $0 = path }
            }
            return ShellOutput(stdoutData: payload, exitCode: 0)
        }
        let data = try await manager.pasteboardData(on: Self.udid, type: "public.png", item: 1)
        #expect(data == payload)
        let arguments = try #require(log.commands.first)
        #expect(
            Array(arguments.prefix(8)) == ["devicectl", "device", "pasteboard", "paste", "--device", Self.udid, "--type", "public.png"])
        #expect(arguments.contains("-") == false, "stdout carries the payload, so the JSON must not go there")
        let path = try #require(jsonPath.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("Pasteboard text reaches devicectl through a file, never argv, and the file is removed")
    func pasteboardText() async throws {
        let staged = Mutex<(path: String, text: String)?>(nil)
        let (manager, log) = manager { command in
            if let index = command.arguments.firstIndex(of: "--file") {
                let path = command.arguments[index + 1]
                let text = try String(contentsOfFile: path, encoding: .utf8)
                staged.withLock { $0 = (path, text) }
            }
            return ShellOutput(
                stdout: #"{"info": {"outcome": "success", "commandType": "x", "jsonVersion": 5}, "result": {}}"#, exitCode: 0)
        }
        try await manager.copyTextToPasteboard("a secret token", on: Self.udid)
        let seen = try #require(staged.withLock { $0 })
        #expect(seen.text == "a secret token")
        #expect(FileManager.default.fileExists(atPath: seen.path) == false)
        #expect(log.commands.flatMap { $0 }.contains { $0.contains("secret") } == false)
        #expect(log.commands.first?.contains("--type") == false)
    }

    @Test("A failure written to the JSON file is still reported")
    func fileFailure() async throws {
        let (manager, _) = manager { command in
            if let index = command.arguments.firstIndex(of: "--json-output") {
                let path = command.arguments[index + 1]
                try Data(try DeviceCtlFixture.text("failure-device-not-found").utf8).write(to: URL(fileURLWithPath: path))
            }
            return ShellOutput(stderr: "ERROR: not found", exitCode: 1)
        }
        let error = await #expect(throws: MobileKitError.self) { try await manager.pasteboardData(on: Self.udid) }
        guard case .coreDeviceFailed(let failure) = error else {
            Issue.record("expected a CoreDevice failure, got \(String(describing: error))")
            return
        }
        #expect(failure.isDeviceNotFound)
    }

    @Test("Console launches return what the app printed")
    func consoleLaunch() async throws {
        let (manager, log) = manager { command in
            if let index = command.arguments.firstIndex(of: "--json-output") {
                let path = command.arguments[index + 1]
                try Data(try DeviceCtlFixture.text("process-launch").utf8).write(to: URL(fileURLWithPath: path))
            }
            return ShellOutput(stdout: "hello from the app\n", exitCode: 0)
        }
        let run = try await manager.launchWithConsole(bundleID: "com.example", on: Self.udid, arguments: ["--flag"])
        #expect(run.output == "hello from the app\n")
        #expect(run.process?.processIdentifier == 63448)
        let arguments = try #require(log.commands.first)
        #expect(arguments.contains("--console"))
        #expect(Array(arguments.suffix(3)) == ["--", "com.example", "--flag"])
    }

    // MARK: - Mutations

    @Test("Operations that change the device send the documented argv")
    func mutations() async throws {
        let (manager, log) = manager { _ in
            ShellOutput(stdout: #"{"info": {"outcome": "success", "commandType": "x", "jsonVersion": 5}, "result": {}}"#, exitCode: 0)
        }
        try await manager.setAppearance(.dark, on: Self.udid)
        try await manager.simulateLocation(latitude: -33.86, longitude: -122.03, on: Self.udid)
        try await manager.clearSimulatedLocation(on: Self.udid)
        try await manager.applyStatusBarPreset(.screenshot, on: Self.udid)
        try await manager.setOrientation(.landscapeLeft, on: Self.udid)
        try await manager.openURL("myapp://x", on: Self.udid)
        try await manager.postNotifications(["a", "b"], on: Self.udid)
        try await manager.setVoiceOver(enabled: true, on: Self.udid)
        try await manager.reboot(Self.udid, style: .userspace)
        try await manager.rename(Self.udid, to: "Lab")
        let u = Self.udid
        #expect(
            log.commands == [
                ["devicectl", "device", "settings", "appearance", "--device", u, "--mode", "dark", "--json-output", "-"],
                [
                    "devicectl", "device", "simulate", "location", "coordinate", "--device", u, "--latitude=-33.86",
                    "--longitude=-122.03", "--json-output", "-",
                ],
                ["devicectl", "device", "simulate", "location", "clear", "--device", u, "--json-output", "-"],
                ["devicectl", "device", "simulate", "statusBar", "preset", "--device", u, "--json-output", "-", "screenshot"],
                ["devicectl", "device", "orientation", "set", "--device", u, "--json-output", "-", "landscapeLeft"],
                ["devicectl", "device", "process", "openURL", "--device", u, "--json-output", "-", "myapp://x"],
                ["devicectl", "device", "notification", "post", "--device", u, "--name", "a", "--name", "b", "--json-output", "-"],
                ["devicectl", "device", "settings", "voiceover", "--device", u, "--enable", "--json-output", "-"],
                ["devicectl", "device", "reboot", "--device", u, "--style", "userspace", "--json-output", "-"],
                ["devicectl", "device", "rename", "--device", u, "--name", "Lab", "--json-output", "-"],
            ])
    }
}
