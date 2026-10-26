import DeviceCtlKit
import Foundation
import Logging
import MobileCore
import SwiftyShell

extension PhysicalIOSDeviceManager {
    /// What a `devicectl` run returned: the decoded JSON document and the stdout that accompanied it.
    struct DeviceCtlRun: Sendable {
        var response: DeviceCtlResponse
        /// stdout as written. It is the command's payload for commands that stream one (pasteboard
        /// paste, launch `--console`); for the rest the JSON went to a file and this is empty.
        var standardOutput: String
        /// The same bytes undecoded, for payloads that are not text.
        var standardOutputData: Data
    }

    /// Runs `ctl` with its JSON on stdout and decodes it.
    ///
    /// Logs before and after the run and on failure, with the operation name and device id but never
    /// arguments or payloads. A CoreDevice error becomes ``MobileKitError/coreDeviceFailed(_:)``.
    @discardableResult
    func perform(
        _ ctl: DeviceCtl,
        operation: String,
        device: String? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> DeviceCtlResponse {
        let command = ctl.jsonOutput()
        let metadata = logMetadata(operation: operation, device: device)
        logger.debug("Running devicectl operation", metadata: metadata)
        let output: ShellOutput
        do {
            output = try await ToolRunner.capture(command, timeout: timeout)
        } catch {
            logger.error(
                "devicectl operation did not run to completion",
                metadata: metadata.merging(["error": "\(Self.logDescription(of: error))"]) { $1 })
            throw error
        }
        return try decode(output, json: output.stdout, command: command, metadata: metadata)
    }

    /// Runs `ctl` with its JSON in a file and stdout left free for the command's own payload.
    ///
    /// For commands that reject `--json-output -` because they write payloads to stdout.
    func performWritingJSONFile(
        _ ctl: DeviceCtl,
        operation: String,
        device: String? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> DeviceCtlRun {
        let path = FileManager.default.temporaryDirectory.appending(path: "devicectl_\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let command = ctl.jsonOutput(path)
        let metadata = logMetadata(operation: operation, device: device)
        logger.debug("Running devicectl operation", metadata: metadata)
        let output: ShellOutput
        do {
            output = try await ToolRunner.capture(command, timeout: timeout)
        } catch {
            logger.error(
                "devicectl operation did not run to completion",
                metadata: metadata.merging(["error": "\(Self.logDescription(of: error))"]) { $1 })
            throw error
        }
        let json = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let response = try decode(output, json: json, command: command, metadata: metadata)
        return DeviceCtlRun(response: response, standardOutput: output.stdout, standardOutputData: output.stdoutData)
    }

    private func decode(
        _ output: ShellOutput,
        json: String,
        command: DeviceCtl,
        metadata: Logger.Metadata
    ) throws -> DeviceCtlResponse {
        let built = command.command()
        let argv = [built.executableName] + built.arguments
        do {
            let response = try DeviceCtlResponse.decode(json: json, output: output, argv: argv)
            logger.debug("devicectl operation succeeded", metadata: metadata)
            return response
        } catch {
            logger.error("devicectl operation failed", metadata: metadata.merging(["error": "\(Self.logDescription(of: error))"]) { $1 })
            throw error
        }
    }

    /// An error reduced to what is safe to log: its kind and code, never the argv, which can hold
    /// environment values, URLs, and file paths a caller passed.
    static func logDescription(of error: Error) -> String {
        switch error {
        case MobileKitError.coreDeviceFailed(let failure): "CoreDevice \(failure.domain) \(failure.code)"
        case MobileKitError.commandFailed(_, let exitCode, _): "devicectl exited \(exitCode)"
        case MobileKitError.timedOut(_, let seconds): "timed out after \(Int(seconds))s"
        case MobileKitError.toolNotFound(let tool): "\(tool) was not found"
        case MobileKitError.unexpectedOutput: "unexpected output"
        default: String(describing: type(of: error))
        }
    }

    private func logMetadata(operation: String, device: String?) -> Logger.Metadata {
        var metadata: Logger.Metadata = ["operation": "\(operation)"]
        if let device { metadata["device"] = "\(device)" }
        return metadata
    }

    /// A fresh path in the temporary directory for a file devicectl writes or reads.
    static func temporaryPath(_ stem: String, extension fileExtension: String) -> String {
        FileManager.default.temporaryDirectory.appending(path: "\(stem)_\(UUID().uuidString).\(fileExtension)").path
    }

    /// Spawns `ctl` for an operation that runs until the caller stops it.
    func spawn(_ ctl: DeviceCtl, operation: String, device: String? = nil) async throws -> any SpawnedProcess {
        let metadata = logMetadata(operation: operation, device: device)
        logger.info("Starting long-running devicectl operation", metadata: metadata)
        do {
            let process = try await ctl.spawn(teardown: .interruptThenTerminate)
            logger.info(
                "Started long-running devicectl operation",
                metadata: metadata.merging(["pid": "\(process.processIdentifier)"]) { $1 })
            return process
        } catch let error as ShellError {
            logger.error(
                "Long-running devicectl operation failed to start",
                metadata: metadata.merging(["error": "\(Self.logDescription(of: error))"]) { $1 })
            throw ToolRunner.map(error, argv: ["xcrun"] + ctl.command().arguments)
        }
    }

    /// Interrupts a process ``spawn(_:operation:device:)`` returned, then waits for it to exit so any
    /// file it was writing is finalized. A process that outlasts `timeout` is torn down.
    func stop(_ process: any SpawnedProcess, operation: String, timeout: Duration) async throws -> ShellOutput {
        logger.info("Stopping devicectl operation", metadata: ["operation": "\(operation)", "pid": "\(process.processIdentifier)"])
        try await process.interrupt()
        let output = await RecordingProcess.waitForExit(process, timeout: timeout)
        logger.info("Stopped devicectl operation", metadata: ["operation": "\(operation)", "exit": "\(output.exitCode)"])
        return output
    }
}
