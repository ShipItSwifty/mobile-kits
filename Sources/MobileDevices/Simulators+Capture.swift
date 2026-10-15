import Foundation
import MobileCore
import SwiftyShell
import XcrunKit

/// Image encodings `simctl io screenshot --type` accepts.
public enum SimulatorImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case tiff
    case bmp
    case gif
}

extension SimulatorManager {
    // MARK: - Screenshots

    /// Captures the screen and returns the encoded image.
    ///
    /// Runs `simctl io <udid> screenshot --type=<format> <tmpfile>`, reads the file, and removes it
    /// whether or not the capture succeeded.
    public func screenshot(
        _ udid: String,
        format: SimulatorImageFormat = .png,
        timeout: Duration = .seconds(30)
    ) async throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "simulator_screenshot_\(UUID().uuidString).\(format.rawValue)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        logger.debug("Capturing simulator screenshot", metadata: ["udid": "\(udid)", "format": "\(format.rawValue)"])
        try await ToolRunner.run(
            Simctl(context: shell).io(udid, command: "screenshot", arguments: ["--type=\(format.rawValue)", path]),
            timeout: timeout
        )
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            logger.debug("Captured simulator screenshot", metadata: ["udid": "\(udid)", "bytes": "\(data.count)"])
            return data
        } catch {
            logger.error("Screenshot file was not readable", metadata: ["udid": "\(udid)", "error": "\(error)"])
            throw MobileKitError.unexpectedOutput(
                tool: "simctl io screenshot", detail: "no image was written: \(error.localizedDescription)")
        }
    }

    // MARK: - Video recording

    /// Starts `simctl io <udid> recordVideo --codec=h264 --force <outputPath>` and returns its pid.
    ///
    /// The recording runs until ``stopRecording(pid:)``. The process stays tracked in a registry
    /// shared by every `SimulatorManager`, so a different instance (or call stack) can stop it by pid.
    /// The mp4 is only finalized once the process receives SIGINT, which `stopRecording` sends.
    public func startRecording(on udid: String, to outputPath: String) async throws -> Int32 {
        logger.info("Starting simulator recording", metadata: ["udid": "\(udid)"])
        let recorder = Simctl(context: shell).io(
            udid, command: "recordVideo", arguments: ["--codec=h264", "--force", outputPath]
        )
        let process: any SpawnedProcess
        do {
            process = try await recorder.spawn(teardown: .interruptThenTerminate)
        } catch let error as ShellError {
            logger.error("Simulator recording failed to start", metadata: ["udid": "\(udid)", "error": "\(error)"])
            throw ToolRunner.map(error, argv: ["xcrun"] + recorder.command().arguments)
        }
        await SimulatorRecordingRegistry.shared.register(process)
        logger.info("Simulator recording started", metadata: ["udid": "\(udid)", "pid": "\(process.processIdentifier)"])
        return process.processIdentifier
    }

    /// Stops a recording so the video file is finalized.
    ///
    /// A recording this process started is sent SIGINT and awaited for up to `timeout` (then torn
    /// down). A pid that is not tracked here, e.g. one started by an earlier run, gets
    /// `kill -INT <pid>` instead and is not awaited.
    public func stopRecording(pid: Int32, timeout: Duration = .seconds(20)) async throws {
        logger.info("Stopping simulator recording", metadata: ["pid": "\(pid)"])
        if let process = await SimulatorRecordingRegistry.shared.remove(pid: pid) {
            do {
                try await process.interrupt()
            } catch {
                logger.error("Interrupting the recording failed", metadata: ["pid": "\(pid)", "error": "\(error)"])
            }
            _ = await RecordingProcess.waitForExit(process, timeout: timeout)
        } else {
            try await ToolRunner.run(
                Command("kill", arguments: ["-INT", String(pid)]), context: shell)
        }
        logger.info("Simulator recording stopped", metadata: ["pid": "\(pid)"])
    }

    /// Whether `pid` is a recording started through this library that has not been stopped.
    public func isRecording(pid: Int32) async -> Bool {
        await SimulatorRecordingRegistry.shared.contains(pid: pid)
    }

}

/// Live `recordVideo` processes by pid, shared so any manager instance can stop one.
actor SimulatorRecordingRegistry {
    static let shared = SimulatorRecordingRegistry()

    private var processes: [Int32: any SpawnedProcess] = [:]

    func register(_ process: any SpawnedProcess) {
        processes[process.processIdentifier] = process
    }

    func remove(pid: Int32) -> (any SpawnedProcess)? {
        processes.removeValue(forKey: pid)
    }

    func contains(pid: Int32) -> Bool {
        processes[pid] != nil
    }
}
