import AdbKit
import Foundation
import Logging
import MobileCore
import SwiftyShell

/// One device `adb devices -l` reports: an emulator or real hardware.
public struct AndroidDevice: Codable, Sendable, Hashable, Identifiable {
    /// adb connection states. Only `.device` accepts commands.
    public enum State: String, Codable, Sendable {
        case device
        case offline
        case unauthorized
        case bootloader
        case recovery
        case noPermissions = "no permissions"
        case unknown
    }

    public var serial: String
    public var state: State
    public var model: String?
    public var product: String?
    public var deviceName: String?
    public var transportID: String?

    public var id: String { serial }

    /// adb names emulators `emulator-<console port>`; everything else is hardware (USB or `host:port`).
    public var kind: DeviceKind { serial.hasPrefix("emulator-") ? .emulator : .physical }

    /// The emulator console port, from `emulator-<port>`.
    public var emulatorConsolePort: Int? {
        kind == .emulator ? Int(serial.dropFirst("emulator-".count)) : nil
    }

    public init(
        serial: String,
        state: State,
        model: String? = nil,
        product: String? = nil,
        deviceName: String? = nil,
        transportID: String? = nil
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.deviceName = deviceName
        self.transportID = transportID
    }
}

/// Inventory, boot waits, app management, and recovery for Android devices through `adb`.
public struct AndroidDeviceManager: Sendable {
    private let shell: ShellContext
    private let poll: (@Sendable (Duration) -> Poller)?
    private let logger = Logger.forType(AndroidDeviceManager.self)

    /// - Parameter poll: Builds the poller boot waits use; `nil` polls every 2 seconds. Injected in tests.
    public init(shell: ShellContext = .init(), poll: (@Sendable (Duration) -> Poller)? = nil) {
        self.shell = shell
        self.poll = poll
    }

    private func adb(_ serial: String? = nil) -> Adb {
        Adb(context: shell).serial(serial)
    }

    // MARK: - Inventory

    /// Devices adb currently sees, in every state.
    public func list() async throws -> [AndroidDevice] {
        let output = try await ToolRunner.run(adb().devices(long: true), timeout: .seconds(30))
        return Self.parseDevices(output.stdout)
    }

    /// Parses `adb devices -l`.
    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> AndroidDevice? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("List of devices"), !text.hasPrefix("*") else { return nil }
            let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            // "no permissions" is two words; it is followed by a bracketed hint.
            var index = 1
            let state: AndroidDevice.State
            if fields[1] == "no", fields.count > 2, fields[2] == "permissions" {
                state = .noPermissions
                index = 3
            } else {
                state = AndroidDevice.State(rawValue: fields[1]) ?? .unknown
                index = 2
            }
            var properties: [String: String] = [:]
            for field in fields.dropFirst(index) {
                let pair = field.split(separator: ":", maxSplits: 1).map(String.init)
                if pair.count == 2 { properties[pair[0]] = pair[1] }
            }
            return AndroidDevice(
                serial: fields[0], state: state, model: properties["model"], product: properties["product"],
                deviceName: properties["device"], transportID: properties["transport_id"]
            )
        }
    }

    // MARK: - Readiness

    /// Waits until `serial` is online and `sys.boot_completed` is `1`.
    ///
    /// - Parameter stop: Return an error to abort early, e.g. when the emulator process exited.
    public func waitForBoot(
        _ serial: String,
        timeout: Duration = .seconds(300),
        stop: (@Sendable () async -> Error?)? = nil
    ) async throws {
        logger.info("Waiting for Android boot", metadata: ["serial": "\(serial)"])
        let adb = adb(serial)
        let poller = poll?(timeout) ?? Poller(timeout: timeout, interval: .seconds(2))
        _ = try await poller.until("boot of \(serial)", stop: stop) { () -> Bool? in
            guard let output = try? await ToolRunner.capture(adb.getprop("sys.boot_completed"), timeout: .seconds(10)),
                output.exitCode == 0, output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            else { return nil }
            return true
        }
        logger.info("Android device booted", metadata: ["serial": "\(serial)"])
    }

    /// Whether the device answers a trivial shell command within `timeout`.
    public func isResponsive(_ serial: String, timeout: Duration = .seconds(10)) async -> Bool {
        guard let output = try? await ToolRunner.capture(adb(serial).shell("echo ok"), timeout: timeout) else { return false }
        return output.exitCode == 0 && output.stdout.contains("ok")
    }

    // MARK: - Apps

    /// - Parameters:
    ///   - grantPermissions: `-g`, grant every runtime permission at install.
    ///   - allowTestPackages: `-t`, needed for instrumentation APKs.
    public func install(
        apkAt path: String,
        on serial: String,
        replace: Bool = true,
        allowTestPackages: Bool = false,
        grantPermissions: Bool = false
    ) async throws {
        logger.info("Installing APK", metadata: ["serial": "\(serial)"])
        try await ToolRunner.run(
            adb(serial).install(
                apk: path, replace: replace, allowTestPackages: allowTestPackages, grantAllPermissions: grantPermissions),
            timeout: .seconds(300)
        )
    }

    public func uninstall(package: String, from serial: String) async throws {
        try await ToolRunner.run(adb(serial).uninstall(package: package), timeout: .seconds(60))
    }

    /// The launcher activity component (`package/.MainActivity`) for `package`.
    public func launchableActivity(package: String, on serial: String) async throws -> String {
        let output = try await ToolRunner.run(adb(serial).resolveLaunchableActivity(package: package), timeout: .seconds(30))
        guard
            let component = output.stdout.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { $0.contains("/") })
        else {
            throw MobileKitError.notFound("No launchable activity for \(package) on \(serial)")
        }
        return component
    }

    /// Starts the app's launcher activity (or `activity` when given).
    public func launch(
        package: String,
        on serial: String,
        activity: String? = nil,
        extras: [String: String] = [:]
    ) async throws {
        let component: String
        if let activity {
            component = "\(package)/\(activity)"
        } else {
            component = try await launchableActivity(package: package, on: serial)
        }
        try await ToolRunner.run(adb(serial).amStartActivity(component: component, extras: extras), timeout: .seconds(60))
    }

    /// `am force-stop`.
    public func terminate(package: String, on serial: String) async throws {
        try await ToolRunner.run(adb(serial).amForceStop(package: package), timeout: .seconds(30))
    }

    /// Force-stops and launches the app again, keeping its data.
    public func relaunch(package: String, on serial: String, activity: String? = nil) async throws {
        try await terminate(package: package, on: serial)
        try await launch(package: package, on: serial, activity: activity)
    }

    /// **Mutating**: `pm clear`, deleting the app's data.
    public func clearData(package: String, on serial: String) async throws {
        try await ToolRunner.run(adb(serial).shell("pm clear \(package)"), timeout: .seconds(60))
    }

    // MARK: - Recovery

    /// Restarts the local adb server, which recovers devices stuck `offline` after a host sleep.
    public func restartServer() async throws {
        logger.warning("Restarting adb server")
        _ = try await ToolRunner.capture(adb().killServer(), timeout: .seconds(30))
        try await ToolRunner.run(adb().startServer(), timeout: .seconds(60))
    }

    /// Reconnects an offline or unresponsive device: `adb reconnect`, then a server restart if it
    /// is still not responding.
    public func recover(_ serial: String, timeout: Duration = .seconds(120)) async throws -> RecoveryReport {
        logger.warning("Recovering Android device", metadata: ["serial": "\(serial)"])
        var steps: [String] = []
        _ = try? await ToolRunner.capture(adb(serial).rawArguments(["reconnect"]), timeout: .seconds(30))
        steps.append("reconnect")
        if await isResponsive(serial) {
            return RecoveryReport(steps: steps + ["responsive"], recovered: true)
        }
        try await restartServer()
        steps.append("restart adb server")
        do {
            try await waitForBoot(serial, timeout: timeout)
            steps.append("booted")
        } catch {
            logger.error("Android device did not come back", metadata: ["serial": "\(serial)", "error": "\(error)"])
            return RecoveryReport(steps: steps + ["still unresponsive"], recovered: false)
        }
        let recovered = await isResponsive(serial)
        return RecoveryReport(steps: steps + [recovered ? "responsive" : "still unresponsive"], recovered: recovered)
    }
}
