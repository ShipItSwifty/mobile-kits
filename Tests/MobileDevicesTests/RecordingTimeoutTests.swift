import Foundation
import MobileCore
import SwiftyShell
import Testing

@testable import MobileDevices

private actor StubbornRecording: SpawnedProcess {
    nonisolated let processIdentifier: Int32 = 424_301
    nonisolated var standardOutput: AsyncStream<String> { AsyncStream { $0.finish() } }
    nonisolated var standardError: AsyncStream<String> { AsyncStream { $0.finish() } }
    private var waiters: [CheckedContinuation<ShellOutput, Never>] = []
    private var finished = false
    private(set) var teardownBeforeRescue = false
    private var rescued = false

    func send(_ signal: ProcessSignal) async throws {}

    func waitForExit() async -> ShellOutput {
        if finished { return ShellOutput(exitCode: 0) }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func teardownAndWait() async -> ShellOutput {
        teardownBeforeRescue = !rescued
        finish()
        return ShellOutput(exitCode: 0)
    }

    func rescue() {
        rescued = true
        finish()
    }

    private func finish() {
        finished = true
        for waiter in waiters { waiter.resume(returning: ShellOutput(exitCode: 0)) }
        waiters.removeAll()
    }
}

@Suite("Recording timeout", .serialized)
struct RecordingTimeoutTests {
    @Test("Timeout tears down a recorder before draining its uncancellable exit wait", arguments: [false, true])
    func teardownBeforeDraining(cancelled: Bool) async throws {
        let process = StubbornRecording()
        await SimulatorRecordingRegistry.shared.register(process)
        // The rescue bounds a broken implementation without making the assertion depend on elapsed time.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                await process.rescue()
            }
            group.addTask {
                if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                try? await SimulatorManager().stopRecording(pid: process.processIdentifier, timeout: .milliseconds(1))
            }
            await group.waitForAll()
        }
        #expect(await process.teardownBeforeRescue)
    }
}

private struct ExitedRecording: SpawnedProcess {
    let processIdentifier: Int32 = 424_302
    var standardOutput: AsyncStream<String> { AsyncStream { $0.finish() } }
    var standardError: AsyncStream<String> { AsyncStream { $0.finish() } }
    let exitCode: Int32
    func send(_ signal: ProcessSignal) async throws { throw ShellError.invalidConfiguration(description: "Process already exited") }
    func waitForExit() async -> ShellOutput { ShellOutput(stderr: "encoder unavailable", exitCode: exitCode) }
    func teardownAndWait() async -> ShellOutput { await waitForExit() }
}

@Suite("Android recording shutdown")
struct AndroidRecordingShutdownTests {
    @Test("An already-exited recorder reports its output instead of a signal error", arguments: [Int32(0), Int32(1), Int32(130)])
    func alreadyExited(exitCode: Int32) async throws {
        let registry = AndroidRecordingRegistry()
        #expect(await registry.reserve(serial: "S"))
        #expect(await registry.attach(ExitedRecording(exitCode: exitCode), serial: "S"))
        let devices = AndroidDeviceManager(shell: ShellContext(executor: MockExecutor()), recordings: registry)
        do {
            try await devices.stopRecording(on: "S")
            #expect(exitCode != 1)
        } catch let MobileKitError.commandFailed(_, actual, output) {
            #expect(actual == 1)
            #expect(output == "encoder unavailable")
        }
        #expect(await !devices.isRecording(on: "S"))
    }

    @Test("An encoder that never creates output releases its reservation and reports its stderr")
    func readinessFailure() async throws {
        let registry = AndroidRecordingRegistry()
        let executor = MockExecutor { command, _ in
            if command.arguments.contains("screenrecord") {
                return ShellOutput(stderr: "encoder unavailable", exitCode: 1)
            }
            return ShellOutput(exitCode: command.arguments.contains(where: { $0.hasPrefix("test -s") }) ? 1 : 0)
        }
        let devices = AndroidDeviceManager(shell: ShellContext(executor: executor), recordings: registry)
        await #expect(
            throws: MobileKitError.commandFailed(
                command: ["adb", "-s", "S", "shell", "screenrecord"], exitCode: 1, output: "encoder unavailable")
        ) {
            try await devices.startRecording(on: "S", remotePath: "/sdcard/a.mp4", readinessTimeout: .zero)
        }
        #expect(await !devices.isRecording(on: "S"))
    }

    @Test("Android recording also tears down before draining a stuck wait")
    func ignoresInterrupt() async throws {
        let registry = AndroidRecordingRegistry()
        let process = StubbornRecording()
        _ = await registry.reserve(serial: "S")
        _ = await registry.attach(process, serial: "S")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                await process.rescue()
            }
            group.addTask {
                try? await AndroidDeviceManager(shell: ShellContext(executor: MockExecutor()), recordings: registry).stopRecording(
                    on: "S", timeout: .milliseconds(1))
            }
        }
        #expect(await process.teardownBeforeRescue)
    }
}
