import AdbKit
import Foundation
import MobileCore
import SwiftyShell

/// How ``AndroidDeviceManager/launch(package:on:options:)`` starts an app.
public struct AndroidLaunchOptions: Sendable, Equatable {
    /// The activity to start: `.MainActivity`, `com.example.Main`, or a full `package/class`
    /// component. `nil` resolves the MAIN/LAUNCHER activity.
    public var activity: String?
    /// Launch arguments. One goes as `--es arg <value>`, several as one `--esa args a,b,c`.
    public var arguments: [String]
    /// Passed as `--es KEY VALUE` extras, sorted by key; Android apps have no process environment.
    public var environment: [String: String]
    /// `--activity-clear-top`, so an already running task returns to the launched activity.
    public var clearTop: Bool
    /// Force-stop the app first so a fresh `onCreate` sees the extras. `nil` does so exactly when
    /// ``environment`` is not empty.
    public var forceStopFirst: Bool?

    public init(
        activity: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        clearTop: Bool = true,
        forceStopFirst: Bool? = nil
    ) {
        self.activity = activity
        self.arguments = arguments
        self.environment = environment
        self.clearTop = clearTop
        self.forceStopFirst = forceStopFirst
    }
}

extension AndroidDeviceManager {
    // MARK: - Server and emulator control

    /// Starts the local adb server if it is not running.
    public func startServer() async throws {
        logger.info("Starting adb server")
        try await ToolRunner.run(adb().startServer(), timeout: .seconds(60))
    }

    /// `adb -s <serial> emu kill`: shuts down a running emulator.
    public func killEmulator(_ serial: String) async throws {
        logger.info("Killing emulator", metadata: ["serial": "\(serial)"])
        try await ToolRunner.run(adb(serial).emuKill(), timeout: .seconds(30))
    }

    // MARK: - Packages

    /// The raw stdout of `adb shell pm list packages` (`package:<id>` lines).
    public func installedPackagesOutput(on serial: String) async throws -> String {
        try await ToolRunner.run(adb(serial).pmListPackages(), timeout: .seconds(20)).stdout
    }

    /// Installed package ids.
    public func installedPackages(on serial: String) async throws -> [String] {
        Self.parsePackages(try await installedPackagesOutput(on: serial))
    }

    /// Parses `pm list packages` output into package ids, in output order.
    public static func parsePackages(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("package:") else { return nil }
            let name = String(text.dropFirst("package:".count))
            return name.isEmpty ? nil : name
        }
    }

    // MARK: - Configuration

    /// `pm grant`: grants a runtime permission, e.g. `android.permission.CAMERA`.
    public func grantPermission(_ permission: String, to package: String, on serial: String) async throws {
        logger.info("Granting permission", metadata: ["serial": "\(serial)", "package": "\(package)", "permission": "\(permission)"])
        try await ToolRunner.run(
            adb(serial).pmGrantPermission(package: package, permission: permission), timeout: .seconds(30))
    }

    /// `pm revoke`: revokes a runtime permission.
    public func revokePermission(_ permission: String, from package: String, on serial: String) async throws {
        logger.info("Revoking permission", metadata: ["serial": "\(serial)", "package": "\(package)", "permission": "\(permission)"])
        try await ToolRunner.run(
            adb(serial).pmRevokePermission(package: package, permission: permission), timeout: .seconds(30))
    }

    /// `am start -a android.intent.action.VIEW -d <url>`: opens a URL or deep link.
    public func openURL(_ url: String, on serial: String) async throws {
        logger.info("Opening URL", metadata: ["serial": "\(serial)"])
        try await ToolRunner.run(adb(serial).amStartViewURL(url), timeout: .seconds(30))
    }

    // MARK: - Port forwarding

    /// `adb forward tcp:<local> tcp:<remote>`.
    public func forwardPort(local: Int, remote: Int, on serial: String) async throws {
        logger.info("Forwarding port", metadata: ["serial": "\(serial)", "local": "\(local)", "remote": "\(remote)"])
        try await ToolRunner.run(adb(serial).forwardTCP(localPort: local, remotePort: remote), timeout: .seconds(30))
    }

    /// `adb forward --remove tcp:<local>`.
    public func removeForward(local: Int, on serial: String) async throws {
        logger.info("Removing port forward", metadata: ["serial": "\(serial)", "local": "\(local)"])
        try await ToolRunner.run(adb(serial).removeForwardTCP(localPort: local), timeout: .seconds(30))
    }

    // MARK: - Capture

    /// A PNG screenshot: `screencap` to the device's `/sdcard`, `pull` to a temporary file, then
    /// delete both copies.
    public func screenshot(on serial: String) async throws -> Data {
        let id = UUID().uuidString
        let remotePath = "/sdcard/mobilekits_screenshot_\(id).png"
        let localPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("mobilekits_screenshot_\(id).png")
        logger.info("Capturing screenshot", metadata: ["serial": "\(serial)"])
        let timeout = Duration.seconds(20)
        do {
            try await ToolRunner.run(adb(serial).screencap(remotePath: remotePath), timeout: timeout)
            try await ToolRunner.run(adb(serial).pull(remote: remotePath, local: localPath), timeout: timeout)
        } catch {
            logger.error("Screenshot failed", metadata: ["serial": "\(serial)", "error": "\(error)"])
            _ = try? await ToolRunner.capture(adb(serial).shell("rm -f \(remotePath)"), timeout: timeout)
            try? FileManager.default.removeItem(atPath: localPath)
            throw error
        }
        defer { try? FileManager.default.removeItem(atPath: localPath) }
        try await ToolRunner.run(adb(serial).shell("rm -f \(remotePath)"), timeout: timeout)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
            logger.info("Captured screenshot", metadata: ["serial": "\(serial)", "bytes": "\(data.count)"])
            return data
        } catch {
            logger.error("Screenshot unreadable", metadata: ["serial": "\(serial)", "error": "\(error)"])
            throw MobileKitError.unexpectedOutput(tool: "adb pull", detail: "pulled screenshot could not be read")
        }
    }

    /// Whether a recording started through this manager's registry is running on `serial`.
    public func isRecording(on serial: String) async -> Bool {
        await recordings.isRecording(serial: serial)
    }

    /// Starts `adb shell screenrecord <remotePath>` in the background; the file stays on the device
    /// (`adb pull` it after ``stopRecording(on:timeout:)``). Waits up to `readinessTimeout` for
    /// the encoder to open its output before returning, so an immediate stop can finalize it.
    ///
    /// - Throws: ``MobileKitError/invalidRequest(_:)`` when a recording is already active on `serial`.
    public func startRecording(on serial: String, remotePath: String, readinessTimeout: Duration = .seconds(20)) async throws {
        guard await recordings.reserve(serial: serial) else {
            logger.error("Recording already active", metadata: ["serial": "\(serial)"])
            throw MobileKitError.invalidRequest("A recording is already active for \(serial).")
        }
        logger.info("Starting screen recording", metadata: ["serial": "\(serial)"])
        let command = adb(serial).screenrecord(remotePath: remotePath)
        let process: any SpawnedProcess
        do {
            // Boot completion can precede emulated storage mounting on a cold device.
            let parent = (remotePath as NSString).deletingLastPathComponent
            _ = try await Poller(timeout: readinessTimeout, interval: .milliseconds(100)).until("recording storage readiness") {
                let result = try await ToolRunner.capture(
                    adb(serial).shell("test -d \(Self.shellQuoted(parent.isEmpty ? "." : parent))"), timeout: .seconds(5))
                return result.exitCode == 0 ? true : nil
            }
            // A previous output must not make the readiness check succeed before this encoder starts.
            try await ToolRunner.run(adb(serial).shell("rm -f \(Self.shellQuoted(remotePath))"), timeout: .seconds(10))
            process = try await command.spawn(captureOutput: true, teardown: .interruptThenTerminate)
        } catch {
            await recordings.cancel(serial: serial)
            logger.error("Screen recording failed to start", metadata: ["serial": "\(serial)", "error": "\(error)"])
            if let error = error as? ShellError {
                throw ToolRunner.map(error, argv: ["adb"] + command.command().arguments)
            }
            throw error
        }
        do {
            // A cold emulator can need seconds to initialize the encoder. SIGINT before that
            // point kills it without producing a movie, so return only once it has opened output.
            _ = try await Poller(timeout: readinessTimeout, interval: .milliseconds(100)).until("screen recording readiness") {
                let result = try await ToolRunner.capture(
                    adb(serial).shell("test -s \(Self.shellQuoted(remotePath))"), timeout: .seconds(5))
                return result.exitCode == 0 ? true : nil
            }
        } catch {
            logger.error("Screen recording did not become ready", metadata: ["serial": "\(serial)"])
            await recordings.cancel(serial: serial)
            _ = try? await ToolRunner.capture(adb(serial).shellPkill(process: "screenrecord"), timeout: .seconds(5))
            let output = await RecordingProcess.waitForExit(process, timeout: .seconds(5))
            if output.exitCode != 0 && output.exitCode != 130 {
                throw MobileKitError.commandFailed(
                    command: ["adb", "-s", serial, "shell", "screenrecord"], exitCode: output.exitCode,
                    output: [output.stderr, output.stdout].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            throw error
        }
        if await !recordings.attach(process, serial: serial) {
            // stopRecording ran while the process was starting.
            _ = try? await ToolRunner.capture(adb(serial).shellPkill(process: "screenrecord"), timeout: .seconds(5))
            _ = await RecordingProcess.waitForExit(process, timeout: .seconds(5))
        }
        logger.info("Started screen recording", metadata: ["serial": "\(serial)"])
    }

    /// Stops the recording started by ``startRecording(on:remotePath:readinessTimeout:)``: SIGINT, then wait for
    /// `screenrecord` to finalize the file. The signal is sent on the device with `pkill`, not
    /// to the host adb client. A tracked client is awaited up to `timeout`, then torn down.
    public func stopRecording(on serial: String, timeout: Duration = .seconds(20)) async throws {
        logger.info("Stopping screen recording", metadata: ["serial": "\(serial)"])
        if let process = await recordings.remove(serial: serial) {
            // Interrupt screenrecord on the device. Interrupting the host adb client instead
            // disconnects its shell and can kill the encoder before it finalizes the MP4.
            _ = try? await ToolRunner.capture(adb(serial).shellPkill(process: "screenrecord"), timeout: .seconds(30))
            let output = await RecordingProcess.waitForExit(process, timeout: timeout)
            // adb may report the remote SIGINT as 128 + SIGINT even after screenrecord finalized.
            if output.exitCode != 0 && output.exitCode != 130 {
                logger.error("Recorder failed", metadata: ["serial": "\(serial)", "exit": "\(output.exitCode)"])
                throw MobileKitError.commandFailed(
                    command: ["adb", "-s", serial, "shell", "screenrecord"], exitCode: output.exitCode,
                    output: [output.stderr, output.stdout].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            logger.info("Stopped screen recording", metadata: ["serial": "\(serial)"])
            return
        }
        try await ToolRunner.run(adb(serial).shellPkill(process: "screenrecord"), timeout: .seconds(30))
        logger.info("Stopped untracked screen recording", metadata: ["serial": "\(serial)"])
    }
}

/// Tracks the `screenrecord` processes ``AndroidDeviceManager`` started, keyed by device serial.
///
/// Manager values are cheap and created freely, so the default registry (``shared``) is process-wide.
public actor AndroidRecordingRegistry {
    /// The process-wide registry managers use by default.
    public static let shared = AndroidRecordingRegistry()

    private enum Entry {
        case starting
        case running(any SpawnedProcess)
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Whether a recording is starting or running on `serial`.
    public func isRecording(serial: String) -> Bool {
        entries[serial] != nil
    }

    /// Claims `serial` for a recording about to start; `false` when one is already active.
    func reserve(serial: String) -> Bool {
        guard entries[serial] == nil else { return false }
        entries[serial] = .starting
        return true
    }

    /// Releases a reservation whose process failed to spawn.
    func cancel(serial: String) {
        if case .starting? = entries[serial] { entries[serial] = nil }
    }

    /// Records the spawned process; `false` when the reservation was removed meanwhile.
    func attach(_ process: any SpawnedProcess, serial: String) -> Bool {
        guard case .starting? = entries[serial] else { return false }
        entries[serial] = .running(process)
        return true
    }

    /// Removes the entry, returning its process when one is running.
    func remove(serial: String) -> (any SpawnedProcess)? {
        guard case .running(let process)? = entries.removeValue(forKey: serial) else { return nil }
        return process
    }
}
