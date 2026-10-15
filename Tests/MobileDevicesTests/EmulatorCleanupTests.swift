import MobileCore
import SwiftyShell
import Testing

@testable import MobileDevices

@Suite("Emulator failure cleanup")
struct EmulatorCleanupTests {
    @Test("Boot and recovery stop their new instance after timeout or cancellation", arguments: [false, true], [false, true])
    func failedBootCleansUp(recovery: Bool, cancelled: Bool) async throws {
        let executor = MockExecutor(stdout: "")
        let shell = ShellContext(executor: executor)
        let devices = AndroidDeviceManager(shell: shell) { Poller(timeout: $0, interval: .milliseconds(1)) }
        let manager = AndroidEmulatorManager(shell: shell, devices: devices)
        let options = EmulatorBootOptions(port: 5564, attached: true)
        let task = Task {
            if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            if recovery {
                let previous = EmulatorInstance(avd: "Pixel", serial: "emulator-5564", pid: 1, process: MockSpawnedProcess())
                _ = try await manager.recover(previous, options: options, timeout: .zero)
            } else {
                _ = try await manager.boot(avd: "Pixel", options: options, timeout: .zero)
            }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        let kills = executor.recordedCommands.filter { $0.arguments == ["-s", "emulator-5564", "emu", "kill"] }
        #expect(kills.count == (recovery ? 2 : 1))
    }
}
