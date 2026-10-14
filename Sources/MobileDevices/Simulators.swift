import Foundation
import Logging
import MobileCore
import SwiftyShell
import XcrunKit

/// One iOS, iPadOS, tvOS, watchOS, or visionOS Simulator as `simctl` reports it.
public struct Simulator: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case shutdown = "Shutdown"
        case booted = "Booted"
        case booting = "Booting"
        case shuttingDown = "Shutting Down"
        case creating = "Creating"
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .unknown
        }
    }

    public var udid: String
    public var name: String
    public var state: State
    public var isAvailable: Bool
    public var deviceTypeIdentifier: String?
    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-0`.
    public var runtimeIdentifier: String

    public var id: String { udid }

    /// `iOS`, `tvOS`, `watchOS`, `xrOS`, from the runtime identifier.
    public var osName: String? { Self.runtimeComponents(runtimeIdentifier)?.os }

    /// `18.0`, from the runtime identifier.
    public var osVersion: String? { Self.runtimeComponents(runtimeIdentifier)?.version }

    public init(
        udid: String,
        name: String,
        state: State,
        isAvailable: Bool = true,
        deviceTypeIdentifier: String? = nil,
        runtimeIdentifier: String
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
    }

    static func runtimeComponents(_ identifier: String) -> (os: String, version: String)? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), parts.dropFirst().joined(separator: "."))
    }
}

/// What `boot` had to do.
public enum BootOutcome: Sendable, Equatable {
    /// This call booted the device; the caller owns shutting it down.
    case booted
    /// The device was already running; the caller must not shut it down on cleanup.
    case alreadyBooted
}

/// The steps ``SimulatorManager/recover(_:bootTimeout:)`` took.
public struct RecoveryReport: Sendable, Equatable {
    public var steps: [String]
    public var recovered: Bool
}

/// Inventory, lifecycle, app management, capture, configuration, and recovery for iOS Simulators
/// through `simctl`.
///
/// Capture lives in `Simulators+Capture.swift` and configuration in `Simulators+Configuration.swift`.
///
/// Mechanisms only: which simulator to pick, how many times to retry, and whether a recovered
/// device may be reused are the caller's decisions.
public struct SimulatorManager: Sendable {
    let shell: ShellContext
    let logger = Logger.forType(SimulatorManager.self)

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    // MARK: - Inventory

    /// Every simulator `simctl` knows; `availableOnly` drops ones whose runtime is missing.
    public func list(availableOnly: Bool = true) async throws -> [Simulator] {
        let output = try await ToolRunner.run(
            Simctl(context: shell).list(.devices, json: true, searchTerm: availableOnly ? "available" : nil),
            timeout: .seconds(30)
        )
        return try Self.parseDevices(output.stdout)
    }

    /// The simulator with `udid`, if it exists.
    public func simulator(udid: String) async throws -> Simulator? {
        try await list(availableOnly: false).first { $0.udid == udid }
    }

    /// Parses `simctl list devices -j`.
    public static func parseDevices(_ json: String) throws -> [Simulator] {
        struct Listing: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
                var state: Simulator.State
                var isAvailable: Bool?
                var deviceTypeIdentifier: String?
            }
            var devices: [String: [Device]]
        }
        let listing: Listing
        do {
            listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        } catch {
            throw MobileKitError.unexpectedOutput(tool: "simctl list devices", detail: String(describing: error))
        }
        return listing.devices
            .flatMap { runtime, devices in
                devices.map {
                    Simulator(
                        udid: $0.udid, name: $0.name, state: $0.state, isAvailable: $0.isAvailable ?? true,
                        deviceTypeIdentifier: $0.deviceTypeIdentifier, runtimeIdentifier: runtime
                    )
                }
            }
            .sorted { ($0.runtimeIdentifier, $0.name, $0.udid) < ($1.runtimeIdentifier, $1.name, $1.udid) }
    }

    // MARK: - Lifecycle

    /// Boots the simulator and waits until it has finished booting.
    ///
    /// - Returns: Whether this call booted it, so cleanup only shuts down what it started.
    @discardableResult
    public func boot(_ udid: String, timeout: Duration = .seconds(240)) async throws -> BootOutcome {
        logger.info("Booting simulator", metadata: ["udid": "\(udid)"])
        let output = try await ToolRunner.capture(Simctl(context: shell).boot(udid), timeout: .seconds(120))
        let outcome: BootOutcome
        if output.exitCode == 0 {
            outcome = .booted
        } else if (output.stderr + output.stdout).contains("current state: Booted")
            || (output.stderr + output.stdout).contains("current state: Booting")
        {
            // Already running, or another caller is booting it: wait for it either way.
            outcome = .alreadyBooted
        } else {
            throw MobileKitError.commandFailed(
                command: ["xcrun", "simctl", "boot", udid], exitCode: output.exitCode,
                output: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await waitUntilBooted(udid, timeout: timeout)
        logger.info("Simulator booted", metadata: ["udid": "\(udid)", "outcome": "\(outcome)"])
        return outcome
    }

    /// `simctl bootstatus <udid> -b`: blocks until SpringBoard and the data migrator are done.
    public func waitUntilBooted(_ udid: String, timeout: Duration = .seconds(240)) async throws {
        try await ToolRunner.run(Simctl(context: shell).bootStatus(udid).arg("-b"), timeout: timeout)
    }

    /// Shuts the simulator down; a simulator that is already shut down is not an error.
    public func shutdown(_ udid: String, timeout: Duration = .seconds(60)) async throws {
        logger.info("Shutting down simulator", metadata: ["udid": "\(udid)"])
        let output = try await ToolRunner.capture(Simctl(context: shell).shutdown([udid]), timeout: timeout)
        guard output.exitCode == 0 || (output.stderr + output.stdout).contains("current state: Shutdown") else {
            throw MobileKitError.commandFailed(
                command: ["xcrun", "simctl", "shutdown", udid], exitCode: output.exitCode,
                output: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// **Mutating**: erases all content and settings. Shuts the simulator down first.
    public func erase(_ udid: String) async throws {
        try await shutdown(udid)
        logger.info("Erasing simulator", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(Simctl(context: shell).erase([udid]), timeout: .seconds(120))
    }

    /// Creates a simulator and returns its UDID.
    ///
    /// - Parameters:
    ///   - deviceType: e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-16` or `iPhone 16`.
    ///   - runtime: e.g. `com.apple.CoreSimulator.SimRuntime.iOS-18-0`.
    public func create(name: String, deviceType: String, runtime: String) async throws -> String {
        let output = try await ToolRunner.run(
            Simctl(context: shell).create(name: name, deviceType: deviceType, runtime: runtime), timeout: .seconds(60))
        return try Self.udid(fromCreateOutput: output.stdout, tool: "simctl create")
    }

    /// Clones a shut-down simulator and returns the clone's UDID.
    public func clone(_ udid: String, name: String) async throws -> String {
        let output = try await ToolRunner.run(Simctl(context: shell).clone(udid, to: name), timeout: .seconds(120))
        return try Self.udid(fromCreateOutput: output.stdout, tool: "simctl clone")
    }

    /// **Mutating**: deletes simulators.
    public func delete(_ udids: [String]) async throws {
        try await ToolRunner.run(Simctl(context: shell).delete(udids), timeout: .seconds(60))
    }

    static func udid(fromCreateOutput output: String, tool: String) throws -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else {
            throw MobileKitError.unexpectedOutput(tool: tool, detail: "expected a UDID, got \(value)")
        }
        return value
    }

    // MARK: - Apps

    public func install(appAt path: String, on udid: String) async throws {
        logger.info("Installing app on simulator", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(Simctl(context: shell).install(udid, appAt: path), timeout: .seconds(300))
    }

    public func uninstall(bundleID: String, from udid: String) async throws {
        try await ToolRunner.run(Simctl(context: shell).uninstall(udid, bundleIdentifier: bundleID), timeout: .seconds(60))
    }

    /// Whether `bundleID` is installed.
    public func isInstalled(bundleID: String, on udid: String) async throws -> Bool {
        let output = try await ToolRunner.capture(
            Simctl(context: shell).getAppContainer(udid, bundleIdentifier: bundleID), timeout: .seconds(30))
        return output.exitCode == 0
    }

    /// Launches an app and returns its process id.
    ///
    /// - Parameters:
    ///   - environment: Passed to the app (simctl reads `SIMCTL_CHILD_<KEY>`).
    ///   - terminateRunning: Start a fresh process even if the app is running. Without it simctl
    ///     re-activates the running process, so a "relaunch" silently keeps old state.
    @discardableResult
    public func launch(
        bundleID: String,
        on udid: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateRunning: Bool = true
    ) async throws -> Int32? {
        var simctl = Simctl(context: shell).custom(
            "launch", arguments: (terminateRunning ? ["--terminate-running-process"] : []) + [udid, bundleID]
        )
        .args(arguments)
        for (key, value) in environment {
            simctl = simctl.env("SIMCTL_CHILD_\(key)", value)
        }
        let output = try await ToolRunner.run(simctl, timeout: .seconds(120))
        return Self.pid(fromLaunchOutput: output.stdout)
    }

    /// Parses `com.example.app: 12345`.
    static func pid(fromLaunchOutput output: String) -> Int32? {
        output.split(separator: "\n").lazy
            .compactMap { $0.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) } }
            .first
    }

    /// Terminates an app; an app that is not running is not an error.
    public func terminate(bundleID: String, on udid: String) async throws {
        let output = try await ToolRunner.capture(
            Simctl(context: shell).terminate(udid, bundleIdentifier: bundleID), timeout: .seconds(30))
        let text = output.stderr + output.stdout
        guard output.exitCode == 0 || text.contains("found nothing to terminate") || text.contains("not running") else {
            throw MobileKitError.commandFailed(
                command: ["xcrun", "simctl", "terminate", udid, bundleID], exitCode: output.exitCode,
                output: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Terminates and launches the app again, keeping its data.
    @discardableResult
    public func relaunch(
        bundleID: String,
        on udid: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> Int32? {
        try await terminate(bundleID: bundleID, on: udid)
        return try await launch(bundleID: bundleID, on: udid, arguments: arguments, environment: environment)
    }

    // MARK: - Health and recovery

    /// Whether the booted simulator answers a trivial request within `timeout`. A hung
    /// CoreSimulator device accepts commands but never completes them.
    public func isResponsive(_ udid: String, timeout: Duration = .seconds(15)) async -> Bool {
        guard let output = try? await ToolRunner.capture(Simctl(context: shell).getenv(udid, variable: "HOME"), timeout: timeout)
        else { return false }
        return output.exitCode == 0 && !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Recovers a hung or half-booted simulator by shutting it down and booting it again.
    ///
    /// Does not erase: data loss is the caller's explicit choice (``erase(_:)``).
    public func recover(_ udid: String, bootTimeout: Duration = .seconds(240)) async throws -> RecoveryReport {
        logger.warning("Recovering simulator", metadata: ["udid": "\(udid)"])
        var steps: [String] = []
        do {
            try await shutdown(udid)
            steps.append("shutdown")
        } catch {
            logger.error("Simulator shutdown failed during recovery", metadata: ["udid": "\(udid)", "error": "\(error)"])
            steps.append("shutdown failed: \(error.localizedDescription)")
        }
        try await boot(udid, timeout: bootTimeout)
        steps.append("boot")
        let recovered = await isResponsive(udid)
        steps.append(recovered ? "responsive" : "still unresponsive")
        logger.info("Simulator recovery finished", metadata: ["udid": "\(udid)", "recovered": "\(recovered)"])
        return RecoveryReport(steps: steps, recovered: recovered)
    }
}
