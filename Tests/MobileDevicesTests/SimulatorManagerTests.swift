import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import Testing

@testable import MobileDevices

@Suite("SimulatorManager")
struct SimulatorManagerTests {
    static let listing = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
            {"udid": "B", "name": "iPhone 16", "state": "Booted", "isAvailable": true,
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"},
            {"udid": "A", "name": "iPad Air", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"udid": "C", "name": "Watch", "state": "Shutting Down", "isAvailable": false}
          ]
        }}
        """

    @Test("Parses simctl's runtime-keyed device listing")
    func parsesListing() throws {
        let devices = try SimulatorManager.parseDevices(Self.listing)
        #expect(devices.map(\.udid) == ["A", "B", "C"])
        let phone = try #require(devices.first { $0.udid == "B" })
        #expect(phone.state == .booted)
        #expect(phone.osName == "iOS")
        #expect(phone.osVersion == "18.2")
        #expect(devices.first { $0.udid == "C" }?.state == .shuttingDown)
        #expect(devices.first { $0.udid == "C" }?.isAvailable == false)
    }

    @Test("Malformed listing is an unexpected-output error")
    func malformedListing() {
        #expect(throws: MobileKitError.self) { try SimulatorManager.parseDevices("not json") }
    }

    @Test("Booting an already booted simulator reports it was not booted by this call")
    func bootAlreadyBooted() async throws {
        let commands = Mutex<[[String]]>([])
        let executor = MockExecutor { command, _ in
            commands.withLock { $0.append(command.arguments) }
            if command.arguments.contains("boot") {
                return ShellOutput(stderr: "Unable to boot device in current state: Booted", exitCode: 149)
            }
            return ShellOutput(exitCode: 0)
        }
        let outcome = try await SimulatorManager(shell: ShellContext(executor: executor)).boot("U")
        #expect(outcome == .alreadyBooted)
        #expect(commands.withLock { $0 } == [["simctl", "boot", "U"], ["simctl", "bootstatus", "U", "-b"]])
    }

    @Test("Racing another booter waits instead of failing")
    func bootWhileBooting() async throws {
        let executor = MockExecutor { command, _ in
            command.arguments.contains("boot")
                ? ShellOutput(stderr: "Unable to boot device in current state: Booting", exitCode: 149) : ShellOutput(exitCode: 0)
        }
        #expect(try await SimulatorManager(shell: ShellContext(executor: executor)).boot("U") == .alreadyBooted)
    }

    @Test("A real boot failure surfaces the command and stderr")
    func bootFailure() async {
        let executor = MockExecutor { _, _ in ShellOutput(stderr: "Invalid device: U", exitCode: 148) }
        await #expect(
            throws: MobileKitError.commandFailed(command: ["xcrun", "simctl", "boot", "U"], exitCode: 148, output: "Invalid device: U")
        ) {
            try await SimulatorManager(shell: ShellContext(executor: executor)).boot("U")
        }
    }

    @Test("Launch passes environment through SIMCTL_CHILD_ and returns the pid")
    func launch() async throws {
        let seen = Mutex<(arguments: [String], environment: [String: String])>(([], [:]))
        let executor = MockExecutor { command, _ in
            seen.withLock { $0 = (command.arguments, command.environmentOverrides) }
            return ShellOutput(stdout: "com.example.app: 4242\n", exitCode: 0)
        }
        let pid = try await SimulatorManager(shell: ShellContext(executor: executor))
            .launch(bundleID: "com.example.app", on: "U", arguments: ["-flag"], environment: ["MODE": "test"])
        #expect(pid == 4242)
        let (arguments, environment) = seen.withLock { $0 }
        #expect(arguments == ["simctl", "launch", "--terminate-running-process", "U", "com.example.app", "-flag"])
        #expect(environment["SIMCTL_CHILD_MODE"] == "test")
    }

    @Test("Terminating an app that is not running is not an error")
    func terminateNotRunning() async throws {
        let executor = MockExecutor { _, _ in
            ShellOutput(stderr: "found nothing to terminate", exitCode: 3)
        }
        try await SimulatorManager(shell: ShellContext(executor: executor)).terminate(bundleID: "b", on: "U")
    }

    @Test("Create returns the new UDID and rejects anything else")
    func createOutput() throws {
        let udid = "6F1B2C3D-1111-2222-3333-444455556666"
        #expect(try SimulatorManager.udid(fromCreateOutput: udid + "\n", tool: "simctl create") == udid)
        #expect(throws: MobileKitError.self) { try SimulatorManager.udid(fromCreateOutput: "error", tool: "simctl create") }
    }

    @Test("Recovery shuts down, boots, and probes responsiveness")
    func recovery() async throws {
        let commands = Mutex<[String]>([])
        let executor = MockExecutor { command, _ in
            commands.withLock { $0.append(command.arguments.dropFirst().first ?? "") }
            if command.arguments.contains("getenv") { return ShellOutput(stdout: "/Users/x\n", exitCode: 0) }
            return ShellOutput(exitCode: 0)
        }
        let report = try await SimulatorManager(shell: ShellContext(executor: executor)).recover("U")
        #expect(report.recovered)
        #expect(report.steps == ["shutdown", "boot", "responsive"])
        #expect(commands.withLock { $0 } == ["shutdown", "boot", "bootstatus", "getenv"])
    }
}
