import DeviceCtlKit
import Foundation
import MobileCore
import SwiftyShell

// `devicectl device process`: launching with a console, opening URLs, and signalling processes.
extension PhysicalIOSDeviceManager {
    /// What a launch with `--console` captured.
    public struct ConsoleLaunch: Sendable, Equatable {
        /// The app's stdout and stderr until it exited.
        public var output: String
        /// The launched process, when devicectl reported it.
        public var process: CoreDeviceLaunchedProcess?
    }

    /// Launches an app attached to the console and waits for it to exit, returning what it printed.
    ///
    /// For apps and test hosts that run to completion. devicectl forwards catchable signals to the
    /// app, so cancelling the caller's task ends the app.
    ///
    /// - Parameter timeout: How long to wait for the app to exit.
    public func launchWithConsole(
        bundleID: String,
        on udid: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateExisting: Bool = true,
        payloadURL: String? = nil,
        options: CoreDeviceLaunchOptions = .init(),
        timeout: Duration = .seconds(600)
    ) async throws -> ConsoleLaunch {
        logger.info("Launching app with console on device", metadata: ["udid": "\(udid)"])
        let run = try await performWritingJSONFile(
            DeviceCtl(context: shell).launch(
                bundleID: bundleID, device: udid, terminateExisting: terminateExisting, console: true, environment: environment,
                payloadURL: payloadURL, options: options, arguments: arguments),
            operation: "process.launch.console", device: udid, timeout: timeout)
        logger.info("App launched with console exited", metadata: ["udid": "\(udid)"])
        return ConsoleLaunch(output: run.standardOutput, process: CoreDeviceLaunchedProcess.parse(run.response.result))
    }

    /// Opens a URL in the app registered for it, such as a universal link or a custom scheme.
    public func openURL(_ url: String, on udid: String, options: CoreDeviceOpenURLOptions = .init()) async throws {
        logger.info("Opening URL on device", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).openURL(url, device: udid, options: options), operation: "process.openURL", device: udid)
        logger.info("Opened URL on device", metadata: ["udid": "\(udid)"])
    }

    /// Terminates a process by id. `force` uses SIGKILL, which the process cannot catch, instead of SIGTERM.
    public func terminate(pid: Int32, on udid: String, force: Bool = false) async throws {
        logger.info("Terminating process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)", "force": "\(force)"])
        try await perform(
            DeviceCtl(context: shell).terminate(pid: pid, device: udid, kill: force), operation: "process.terminate", device: udid)
        logger.info("Terminated process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    /// Sends a signal to a process, named as in `man signal`.
    public func signal(_ signal: String, pid: Int32, on udid: String) async throws {
        logger.info("Signalling process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)", "signal": "\(signal)"])
        try await perform(
            DeviceCtl(context: shell).signal(signal, pid: pid, device: udid), operation: "process.signal", device: udid)
        logger.info("Signalled process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    /// Suspends a process.
    public func suspend(pid: Int32, on udid: String) async throws {
        logger.info("Suspending process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        try await perform(DeviceCtl(context: shell).suspend(pid: pid, device: udid), operation: "process.suspend", device: udid)
        logger.info("Suspended process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    /// Resumes a suspended process, for example an app launched with `startStopped`.
    public func resume(pid: Int32, on udid: String) async throws {
        logger.info("Resuming process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        try await perform(DeviceCtl(context: shell).resume(pid: pid, device: udid), operation: "process.resume", device: udid)
        logger.info("Resumed process on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    /// Sends a memory pressure warning to a process.
    public func sendMemoryWarning(pid: Int32, on udid: String) async throws {
        logger.info("Sending memory warning on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        try await perform(
            DeviceCtl(context: shell).sendMemoryWarning(pid: pid, device: udid), operation: "process.sendMemoryWarning", device: udid)
        logger.info("Sent memory warning on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    /// Waits for a process to exit and returns devicectl's report of its exit status.
    ///
    /// - Parameter timeout: How long to wait for the process to exit.
    public func awaitTermination(pid: Int32, on udid: String, timeout: Duration = .seconds(600)) async throws -> DeviceCtlResponse {
        logger.info("Waiting for process on device to exit", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        let response = try await perform(
            DeviceCtl(context: shell).awaitTermination(pid: pid, device: udid),
            operation: "process.awaitTermination", device: udid, timeout: timeout)
        logger.info("Process on device exited", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        return response
    }
}
