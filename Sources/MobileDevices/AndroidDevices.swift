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
    let shell: ShellContext
    let recordings: AndroidRecordingRegistry
    private let poll: (@Sendable (Duration) -> Poller)?
    let logger = Logger.forType(AndroidDeviceManager.self)

    /// - Parameters:
    ///   - recordings: Tracks running screen recordings. Defaults to the process-wide registry, so a
    ///     recording started by one manager value can be stopped by another; tests inject their own.
    ///   - poll: Builds the poller boot waits use; `nil` polls every 2 seconds. Injected in tests.
    public init(
        shell: ShellContext = .init(),
        recordings: AndroidRecordingRegistry = .shared,
        poll: (@Sendable (Duration) -> Poller)? = nil
    ) {
        self.shell = shell
        self.recordings = recordings
        self.poll = poll
    }

    func adb(_ serial: String? = nil) -> Adb {
        Adb(context: shell).serial(serial)
    }

    // MARK: - Inventory

    /// Devices adb currently sees, in every state.
    public func list() async throws -> [AndroidDevice] {
        Self.parseDevices(try await devicesOutput())
    }

    /// The raw stdout of `adb devices -l`.
    public func devicesOutput() async throws -> String {
        try await ToolRunner.run(adb().devices(long: true), timeout: .seconds(30)).stdout
    }

    /// Returns `serial` when given; otherwise the only device in state `.device`, the way `adb`
    /// without `-s` picks its target.
    ///
    /// - Throws: ``MobileKitError/commandFailed(command:exitCode:output:)`` with adb's own messages
    ///   (`no devices/emulators found`, `more than one device/emulator`) when there is not exactly one.
    public func resolveSerial(_ serial: String?) async throws -> String {
        if let serial { return serial }
        let ready = try await list().filter { $0.state == .device }
        guard let only = ready.first, ready.count == 1 else {
            let message = ready.isEmpty ? "adb: no devices/emulators found" : "adb: more than one device/emulator"
            logger.error("Cannot pick an Android device", metadata: ["ready": "\(ready.count)"])
            throw MobileKitError.commandFailed(command: ["adb"], exitCode: 1, output: message)
        }
        return only.serial
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
    ///
    /// Queries the MAIN/LAUNCHER intent filter and takes the last output line that starts with
    /// `<package>/` and has no space; the class may live outside the package (flavors,
    /// `applicationIdSuffix`).
    public func launchableActivity(package: String, on serial: String) async throws -> String {
        let output = try await ToolRunner.run(
            adb(serial).rawArguments(Self.resolveLauncherArguments(package: package)), timeout: .seconds(30))
        guard let component = Self.parseLauncherComponent(output.stdout, package: package) else {
            logger.error("No launchable activity", metadata: ["serial": "\(serial)", "package": "\(package)"])
            throw MobileKitError.notFound("No launchable activity for \(package) on \(serial)")
        }
        return component
    }

    /// `adb shell cmd package resolve-activity --brief` arguments selecting the LAUNCHER activity.
    /// Without the MAIN/LAUNCHER filter the query matches nothing useful, or the system resolver.
    public static func resolveLauncherArguments(package: String) -> [String] {
        [
            "shell", "cmd", "package", "resolve-activity", "--brief",
            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package,
        ]
    }

    /// The `<package>/<class>` component in `resolve-activity --brief` output, or `nil` when
    /// nothing launchable matched. Only the package half is checked, since the class can live elsewhere.
    public static func parseLauncherComponent(_ output: String, package: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix(package + "/") && !$0.contains(" ") }
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
        logger.info("Launching app", metadata: ["serial": "\(serial)", "package": "\(package)"])
        try await ToolRunner.run(adb(serial).amStartActivity(component: component, extras: extras), timeout: .seconds(60))
        logger.info("Launched app", metadata: ["serial": "\(serial)", "package": "\(package)"])
    }

    /// Starts the app with ``AndroidLaunchOptions``: optional force-stop, `--activity-clear-top`,
    /// environment extras, and launch arguments. See ``amStartArguments(component:arguments:environment:clearTop:)``.
    public func launch(package: String, on serial: String, options: AndroidLaunchOptions) async throws {
        let component: String
        if let activity = options.activity {
            component = activity.contains("/") ? activity : "\(package)/\(activity)"
        } else {
            component = try await launchableActivity(package: package, on: serial)
        }
        let forceStop = options.forceStopFirst ?? !options.environment.isEmpty
        logger.info("Launching app", metadata: ["serial": "\(serial)", "package": "\(package)", "forceStop": "\(forceStop)"])
        if forceStop {
            try await terminate(package: package, on: serial)
        }
        let arguments = Self.amStartArguments(
            component: component, arguments: options.arguments, environment: options.environment, clearTop: options.clearTop)
        try await ToolRunner.run(adb(serial).rawArguments(arguments), timeout: .seconds(60))
        logger.info("Launched app", metadata: ["serial": "\(serial)", "package": "\(package)"])
    }

    /// `shell am start [--activity-clear-top] -n <component>` with `environment` as `--es KEY VALUE`
    /// extras (sorted by key; Android has no process environment for apps). One launch argument goes as
    /// `--es arg <value>`; several go as one `--esa args a,b,c`, because repeated `--es arg` extras
    /// overwrite each other. Keys and values are single-quoted when needed: `adb shell` re-tokenizes the
    /// command on the device.
    public static func amStartArguments(
        component: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        clearTop: Bool = true
    ) -> [String] {
        var command = ["shell", "am", "start"]
        if clearTop { command.append("--activity-clear-top") }
        command += ["-n", component]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            command += ["--es", shellQuoted(key), shellQuoted(value)]
        }
        switch arguments.count {
        case 0: break
        case 1: command += ["--es", "arg", shellQuoted(arguments[0])]
        default: command += ["--esa", "args", shellQuoted(arguments.joined(separator: ","))]
        }
        return command
    }

    /// `value` quoted for the device shell: left as is when it only has safe characters, otherwise
    /// single-quoted with embedded quotes escaped; empty becomes `''`.
    public static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.:/=@%+,"))
        guard value.unicodeScalars.contains(where: { !safe.contains($0) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
