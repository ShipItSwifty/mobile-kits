import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import Testing

@testable import MobileDevices

@Suite("AndroidDeviceManager operations")
struct AndroidDeviceOperationsTests {
    private func manager(
        _ executor: MockExecutor, recordings: AndroidRecordingRegistry = AndroidRecordingRegistry()
    ) -> AndroidDeviceManager {
        AndroidDeviceManager(shell: ShellContext(executor: executor), recordings: recordings)
    }

    private func recordedArguments(_ executor: MockExecutor) -> [[String]] {
        executor.recordedCommands.map(\.arguments)
    }

    // MARK: - am start

    @Test("am start: environment extras are sorted and quoted, one argument is --es arg")
    func amStartEnvironmentAndSingleArgument() {
        let arguments = AndroidDeviceManager.amStartArguments(
            component: "com.example/.Main",
            arguments: ["--flag value"],
            environment: ["B": "it's", "A": "plain", "EMPTY": ""]
        )
        #expect(
            arguments == [
                "shell", "am", "start", "--activity-clear-top", "-n", "com.example/.Main",
                "--es", "A", "plain", "--es", "B", "'it'\\''s'", "--es", "EMPTY", "''",
                "--es", "arg", "'--flag value'",
            ])
    }

    @Test("am start: several arguments become one --esa array")
    func amStartMultipleArguments() {
        let arguments = AndroidDeviceManager.amStartArguments(component: "p/.A", arguments: ["a", "b", "c"])
        #expect(arguments == ["shell", "am", "start", "--activity-clear-top", "-n", "p/.A", "--esa", "args", "a,b,c"])
    }

    @Test("am start: clearTop can be disabled and no extras are added without input")
    func amStartPlain() {
        #expect(
            AndroidDeviceManager.amStartArguments(component: "p/.A", clearTop: false) == ["shell", "am", "start", "-n", "p/.A"])
    }

    @Test("shellQuoted leaves safe values alone and escapes the rest")
    func shellQuoting() {
        #expect(AndroidDeviceManager.shellQuoted("abc-1.2:/x=y@z%+,") == "abc-1.2:/x=y@z%+,")
        #expect(AndroidDeviceManager.shellQuoted("") == "''")
        #expect(AndroidDeviceManager.shellQuoted("a b") == "'a b'")
        #expect(AndroidDeviceManager.shellQuoted("a;b$c") == "'a;b$c'")
    }

    // MARK: - Launcher resolution

    @Test("Launcher parsing takes the last <package>/ line without spaces, even for a foreign class")
    func launcherParsing() {
        let output = """
            priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true
            com.example/com.other.Main
            com.example/.Wrong Name
            android/com.android.internal.app.ResolverActivity
            """
        #expect(AndroidDeviceManager.parseLauncherComponent(output, package: "com.example") == "com.example/com.other.Main")
        #expect(AndroidDeviceManager.parseLauncherComponent("No activity found", package: "com.example") == nil)
        #expect(AndroidDeviceManager.parseLauncherComponent("com.example.debug/.Main", package: "com.example") == nil)
    }

    @Test("Launcher resolution queries the MAIN/LAUNCHER filter")
    func launcherArguments() async throws {
        let executor = MockExecutor(stdout: "com.example/.Main\n")
        let component = try await manager(executor).launchableActivity(package: "com.example", on: "S")
        #expect(component == "com.example/.Main")
        #expect(
            recordedArguments(executor) == [
                [
                    "-s", "S", "shell", "cmd", "package", "resolve-activity", "--brief",
                    "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", "com.example",
                ]
            ])
    }

    @Test("Launcher resolution reports a package with no launcher activity")
    func launcherNotFound() async {
        let executor = MockExecutor(stdout: "No activity found\n")
        await #expect(throws: MobileKitError.notFound("No launchable activity for com.example on S")) {
            try await manager(executor).launchableActivity(package: "com.example", on: "S")
        }
    }

    @Test("Launch with options resolves, force-stops for an environment, then starts with extras")
    func launchWithOptions() async throws {
        let executor = MockExecutor { command, _ in
            ShellOutput(stdout: command.arguments.contains("resolve-activity") ? "com.example/.Main\n" : "", exitCode: 0)
        }
        try await manager(executor).launch(
            package: "com.example", on: "S", options: AndroidLaunchOptions(arguments: ["x"], environment: ["K": "v w"]))
        let recorded = recordedArguments(executor)
        #expect(recorded.count == 3)
        #expect(recorded[1] == ["-s", "S", "shell", "am", "force-stop", "com.example"])
        #expect(
            recorded[2] == [
                "-s", "S", "shell", "am", "start", "--activity-clear-top", "-n", "com.example/.Main",
                "--es", "K", "'v w'", "--es", "arg", "x",
            ])
    }

    @Test("Launch with options skips resolution for a given activity and does not force-stop without an environment")
    func launchWithActivity() async throws {
        let executor = MockExecutor(exitCode: 0)
        try await manager(executor).launch(
            package: "com.example", on: "S", options: AndroidLaunchOptions(activity: ".Settings", clearTop: false))
        #expect(recordedArguments(executor) == [["-s", "S", "shell", "am", "start", "-n", "com.example/.Settings"]])
    }

    @Test("forceStopFirst overrides the environment default in both directions")
    func forceStopOverride() async throws {
        let forced = MockExecutor(exitCode: 0)
        try await manager(forced).launch(
            package: "p", on: "S", options: AndroidLaunchOptions(activity: ".A", forceStopFirst: true))
        #expect(recordedArguments(forced).first == ["-s", "S", "shell", "am", "force-stop", "p"])

        let skipped = MockExecutor(exitCode: 0)
        try await manager(skipped).launch(
            package: "p", on: "S", options: AndroidLaunchOptions(activity: "p/.A", environment: ["K": "v"], forceStopFirst: false))
        #expect(recordedArguments(skipped).count == 1)
        #expect(recordedArguments(skipped)[0].contains("p/.A"))
    }

    // MARK: - Simple operations

    @Test("Simple operations build the expected adb argv")
    func simpleOperations() async throws {
        let executor = MockExecutor(exitCode: 0)
        let manager = manager(executor)
        try await manager.startServer()
        try await manager.killEmulator("emulator-5554")
        try await manager.grantPermission("android.permission.CAMERA", to: "com.example", on: "S")
        try await manager.revokePermission("android.permission.CAMERA", from: "com.example", on: "S")
        try await manager.openURL("https://example.com/x", on: "S")
        try await manager.forwardPort(local: 8200, remote: 8300, on: "S")
        try await manager.removeForward(local: 8200, on: "S")
        #expect(
            recordedArguments(executor) == [
                ["start-server"],
                ["-s", "emulator-5554", "emu", "kill"],
                ["-s", "S", "shell", "pm", "grant", "com.example", "android.permission.CAMERA"],
                ["-s", "S", "shell", "pm", "revoke", "com.example", "android.permission.CAMERA"],
                ["-s", "S", "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "https://example.com/x"],
                ["-s", "S", "forward", "tcp:8200", "tcp:8300"],
                ["-s", "S", "forward", "--remove", "tcp:8200"],
            ])
    }

    @Test("Package listing returns raw and parsed output")
    func packages() async throws {
        let raw = "package:com.a\npackage:com.b\n\nWarning: noise\n"
        let executor = MockExecutor(stdout: raw)
        let manager = manager(executor)
        #expect(try await manager.installedPackagesOutput(on: "S") == raw)
        #expect(try await manager.installedPackages(on: "S") == ["com.a", "com.b"])
        #expect(recordedArguments(executor).first == ["-s", "S", "shell", "pm", "list", "packages"])
    }

    @Test("devicesOutput is the raw adb devices -l output")
    func devicesOutput() async throws {
        let executor = MockExecutor(stdout: "List of devices attached\nA device\n")
        #expect(try await manager(executor).devicesOutput() == "List of devices attached\nA device\n")
        #expect(recordedArguments(executor) == [["devices", "-l"]])
    }

    // MARK: - resolveSerial

    private func devicesExecutor(_ lines: String) -> MockExecutor {
        MockExecutor(stdout: "List of devices attached\n\(lines)\n")
    }

    @Test("resolveSerial returns an explicit serial without asking adb")
    func resolveExplicit() async throws {
        let executor = devicesExecutor("")
        #expect(try await manager(executor).resolveSerial("given") == "given")
        #expect(executor.recordedCommands.isEmpty)
    }

    @Test("resolveSerial picks the single ready device and ignores offline ones")
    func resolveSingle() async throws {
        let executor = devicesExecutor("emulator-5554 device\nR58 offline\nXYZ unauthorized")
        #expect(try await manager(executor).resolveSerial(nil) == "emulator-5554")
    }

    @Test("resolveSerial fails like adb with no devices")
    func resolveNone() async {
        let executor = devicesExecutor("R58 offline")
        await #expect(
            throws: MobileKitError.commandFailed(command: ["adb"], exitCode: 1, output: "adb: no devices/emulators found")
        ) {
            try await manager(executor).resolveSerial(nil)
        }
    }

    @Test("resolveSerial fails like adb with several devices")
    func resolveMany() async {
        let executor = devicesExecutor("emulator-5554 device\nemulator-5556 device")
        await #expect(
            throws: MobileKitError.commandFailed(command: ["adb"], exitCode: 1, output: "adb: more than one device/emulator")
        ) {
            try await manager(executor).resolveSerial(nil)
        }
    }

    // MARK: - Screenshot

    @Test("Screenshot captures, pulls, reads, and removes the remote file")
    func screenshot() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let executor = MockExecutor { command, _ in
            if command.arguments.contains("pull"), let local = command.arguments.last {
                try png.write(to: URL(fileURLWithPath: local))
            }
            return ShellOutput(exitCode: 0)
        }
        let data = try await manager(executor).screenshot(on: "S")
        #expect(data == png)
        let recorded = recordedArguments(executor)
        #expect(recorded.count == 3)
        #expect(recorded[0].prefix(4) == ["-s", "S", "shell", "screencap"])
        #expect(recorded[0][4] == "-p")
        let remote = recorded[0][5]
        #expect(remote.hasPrefix("/sdcard/") && remote.hasSuffix(".png"))
        #expect(recorded[1].prefix(4) == ["-s", "S", "pull", remote])
        #expect(recorded[2] == ["-s", "S", "shell", "rm -f \(remote)"])
        #expect(!FileManager.default.fileExists(atPath: recorded[1][4]))
    }

    @Test("Screenshot cleans up the remote file when the pull fails")
    func screenshotPullFailure() async {
        let executor = MockExecutor { command, _ in
            ShellOutput(stderr: "boom", exitCode: command.arguments.contains("pull") ? 1 : 0)
        }
        await #expect(throws: MobileKitError.self) { try await manager(executor).screenshot(on: "S") }
        #expect(recordedArguments(executor).last?.last?.hasPrefix("rm -f /sdcard/") == true)
    }

    // MARK: - Recording

    @Test("Recording spawns screenrecord, refuses a duplicate, and stop interrupts the tracked process")
    func recordingLifecycle() async throws {
        let executor = MockExecutor(exitCode: 0)
        let registry = AndroidRecordingRegistry()
        let manager = manager(executor, recordings: registry)

        try await manager.startRecording(on: "S", remotePath: "/sdcard/a.mp4")
        #expect(recordedArguments(executor) == [["-s", "S", "shell", "screenrecord", "/sdcard/a.mp4"]])
        #expect(await manager.isRecording(on: "S"))

        await #expect(throws: MobileKitError.invalidRequest("A recording is already active for S.")) {
            try await manager.startRecording(on: "S", remotePath: "/sdcard/b.mp4")
        }
        #expect(executor.recordedCommands.count == 1)

        // A different device is independent.
        try await manager.startRecording(on: "T", remotePath: "/sdcard/c.mp4")

        try await manager.stopRecording(on: "S")
        #expect(!(await manager.isRecording(on: "S")))
        #expect(await manager.isRecording(on: "T"))
        // Tracked stop interrupts the process; it never shells out to pkill.
        #expect(!recordedArguments(executor).contains { $0.contains("pkill") })

        // After the stop a new recording is allowed again.
        try await manager.startRecording(on: "S", remotePath: "/sdcard/d.mp4")
        try await manager.stopRecording(on: "S")
        try await manager.stopRecording(on: "T")
    }

    @Test("Stopping an untracked recording falls back to pkill -INT screenrecord")
    func stopUntracked() async throws {
        let executor = MockExecutor(exitCode: 0)
        try await manager(executor).stopRecording(on: "S")
        #expect(recordedArguments(executor) == [["-s", "S", "shell", "pkill", "-INT", "screenrecord"]])
    }

    @Test("A failed spawn releases the reservation")
    func failedSpawnReleases() async throws {
        let failing = Mutex(true)
        let executor = MockExecutor { _, _ in
            if failing.withLock({ $0 }) { throw ShellError.commandNotFound("adb") }
            return ShellOutput(exitCode: 0)
        }
        let registry = AndroidRecordingRegistry()
        let manager = manager(executor, recordings: registry)
        await #expect(throws: MobileKitError.toolNotFound("adb")) {
            try await manager.startRecording(on: "S", remotePath: "/sdcard/a.mp4")
        }
        #expect(!(await manager.isRecording(on: "S")))
        failing.withLock { $0 = false }
        try await manager.startRecording(on: "S", remotePath: "/sdcard/a.mp4")
        try await manager.stopRecording(on: "S")
    }
}

@Suite("EmulatorInstance")
struct EmulatorInstanceTests {
    @Test("Has a public initializer and reads the log tail")
    func logTail() throws {
        let path = NSTemporaryDirectory() + "emulator-instance-\(UUID().uuidString).log"
        try "one\n\ntwo\nthree\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let instance = EmulatorInstance(avd: "Pixel", serial: "emulator-5554", pid: 1, logPath: path)
        #expect(instance.logTail(lines: 2) == "two\nthree")
        #expect(EmulatorInstance(avd: "Pixel", serial: "emulator-5554", pid: 1).logTail() == "")
    }

    @Test("Liveness reports a running child and an exited one")
    func liveness() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        try process.run()
        let instance = EmulatorInstance(avd: "A", serial: "emulator-5554", pid: process.processIdentifier)
        #expect(instance.isRunning())
        process.terminate()
        process.waitUntilExit()
        #expect(!instance.isRunning())
    }
}
