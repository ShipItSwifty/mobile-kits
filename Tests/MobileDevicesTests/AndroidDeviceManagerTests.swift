import Foundation
import MobileCore
import SwiftyShell
import Synchronization
import Testing

@testable import MobileDevices

@Suite("AndroidDeviceManager")
struct AndroidDeviceManagerTests {
    @Test("Parses adb devices -l, including two-word and unauthorized states")
    func parsesDevices() {
        let devices = AndroidDeviceManager.parseDevices(
            """
            * daemon started successfully
            List of devices attached
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            R58M1234ABC            unauthorized usb:1-1 transport_id:2
            192.168.1.5:5555       offline transport_id:3
            0123456789             no permissions (missing udev rules?); see [http://developer.android.com/tools/device.html]

            """)
        #expect(devices.map(\.serial) == ["emulator-5554", "R58M1234ABC", "192.168.1.5:5555", "0123456789"])
        #expect(devices.map(\.state) == [.device, .unauthorized, .offline, .noPermissions])
        #expect(devices[0].kind == .emulator)
        #expect(devices[0].emulatorConsolePort == 5554)
        #expect(devices[0].model == "sdk_gphone64_arm64")
        #expect(devices[1].kind == .physical)
        #expect(devices[1].transportID == "2")
    }

    @Test("Boot wait polls sys.boot_completed until it reads 1")
    func waitForBoot() async throws {
        let calls = Mutex(0)
        let executor = MockExecutor { command, _ in
            #expect(command.arguments == ["-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"])
            let count = calls.withLock { value in
                value += 1
                return value
            }
            return ShellOutput(stdout: count < 3 ? "\n" : "1\n", exitCode: 0)
        }
        let manager = AndroidDeviceManager(shell: ShellContext(executor: executor)) {
            Poller(timeout: $0, interval: .milliseconds(1), sleep: { _ in })
        }
        try await manager.waitForBoot("emulator-5554", timeout: .seconds(5))
        #expect(calls.withLock { $0 } == 3)
    }

    @Test("Boot wait stops early when the stop check reports an error")
    func waitForBootStops() async {
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "\n", exitCode: 0) }
        let manager = AndroidDeviceManager(shell: ShellContext(executor: executor)) {
            Poller(timeout: $0, interval: .milliseconds(1), sleep: { _ in })
        }
        await #expect(throws: MobileKitError.processExited(description: "Emulator P", exitCode: nil, logTail: "")) {
            try await manager.waitForBoot("emulator-5554", timeout: .seconds(5)) {
                MobileKitError.processExited(description: "Emulator P", exitCode: nil, logTail: "")
            }
        }
    }

    @Test("Launch resolves the launcher activity when none is given")
    func launchResolvesActivity() async throws {
        let commands = Mutex<[[String]]>([])
        let executor = MockExecutor { command, _ in
            commands.withLock { $0.append(command.arguments) }
            if command.arguments.contains("resolve-activity") {
                return ShellOutput(stdout: "priority=0 preferredOrder=0\ncom.example/.MainActivity\n", exitCode: 0)
            }
            return ShellOutput(exitCode: 0)
        }
        try await AndroidDeviceManager(shell: ShellContext(executor: executor)).launch(package: "com.example", on: "S")
        let recorded = commands.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded[1].contains("com.example/.MainActivity"))
        #expect(recorded[1].prefix(2) == ["-s", "S"])
    }
}

@Suite("AndroidEmulatorManager attached start")
struct AndroidEmulatorAttachedTests {
    @Test("The emulator running an AVD is found among several, and port selection reuses a listing")
    func runningSerialAmongSeveral() async throws {
        let listCalls = Mutex(0)
        let executor = MockExecutor { command, _ in
            let arguments = command.arguments
            if arguments.contains("devices") {
                listCalls.withLock { $0 += 1 }
                return ShellOutput(
                    stdout: """
                        List of devices attached
                        emulator-5554          device product:a model:a device:a transport_id:1
                        emulator-5556          device product:b model:b device:b transport_id:2
                        emulator-5558          device product:c model:c device:c transport_id:3

                        """, stderr: "", exitCode: 0)
            }
            if arguments.contains("avd") && arguments.contains("name") {
                let name = ["emulator-5554": "Pixel_6", "emulator-5556": "Pixel_7", "emulator-5558": "Pixel_8"][arguments[1]] ?? ""
                return ShellOutput(stdout: "\(name)\nOK\n", stderr: "", exitCode: 0)
            }
            return ShellOutput(stdout: "1\n", stderr: "", exitCode: 0)
        }
        let manager = AndroidEmulatorManager(shell: ShellContext(executor: executor))
        #expect(try await manager.runningSerial(avd: "Pixel_7") == "emulator-5556")
        #expect(try await manager.runningSerial(avd: "Pixel_9") == nil)
        listCalls.withLock { $0 = 0 }
        let booted = try await manager.boot(avd: "Pixel_8", timeout: .seconds(5))
        #expect(booted.serial == "emulator-5558")
        #expect(booted.started == nil)
        #expect(listCalls.withLock { $0 } == 1)

        listCalls.withLock { $0 = 0 }
        let listing = AndroidDeviceManager.parseDevices(
            "List of devices attached\nemulator-5554 device transport_id:1\nemulator-5556 device transport_id:2\n")
        #expect(try await manager.freeConsolePort(listing: listing) == 5558)
        #expect(listCalls.withLock { $0 } == 0, "A supplied listing is reused, not fetched again")
    }

    @Test("An attached emulator is spawned as a child, keeps its process handle, and stops through it")
    func attachedStartAndStop() async throws {
        let seen = Mutex([[String]]())
        let executor = MockExecutor { command, _ in
            seen.withLock { $0.append(command.arguments) }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        let manager = AndroidEmulatorManager(shell: ShellContext(executor: executor))

        let instance = try await manager.start(avd: "Pixel_7", options: EmulatorBootOptions(headless: true, port: 5560, attached: true))

        #expect(instance.serial == "emulator-5560")
        #expect(instance.process != nil)
        #expect(instance.logPath == nil)
        let start = try #require(seen.withLock { $0 }.first)
        #expect(start.contains("-avd") && start.contains("Pixel_7") && start.contains("-no-window"))

        await manager.stop(instance)
        #expect(seen.withLock { $0 }.contains { $0.contains("kill") }, "adb emu kill is sent before the child is torn down")
    }

    @Test("A detached emulator has no process handle and logs to a file")
    func detachedStart() async throws {
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
        let manager = AndroidEmulatorManager(shell: ShellContext(executor: executor))
        let instance = try await manager.start(avd: "Pixel_7", options: EmulatorBootOptions(port: 5562))
        #expect(instance.process == nil)
        #expect(instance.logPath != nil)
    }
}
