import DeviceCtlKit
import Foundation
import IProxyKit
import Logging
import MobileCore
import SwiftyShell

/// A device `devicectl list devices` reports.
public struct PhysicalIOSDevice: Codable, Sendable, Hashable, Identifiable {
    /// The hardware UDID, or the CoreDevice identifier when no UDID is reported.
    public var udid: String
    /// CoreDevice identifier.
    public var identifier: String
    public var name: String
    /// `iOS`, `watchOS`, `tvOS`, `macOS`, `xrOS`.
    public var platform: String
    public var osVersion: String?
    public var model: String?
    /// `wired`, `localNetwork`, `sameMachine` for a simulator, ….
    public var transport: String?
    /// Whether a CoreDevice tunnel is up, i.e. the device can be driven right now.
    public var isConnected: Bool
    public var developerModeEnabled: Bool?
    /// `physical`, or `simulated` for a simulator Xcode 27's devicectl lists. Older versions omit it.
    public var reality: String?

    public var id: String { udid }

    /// Whether this is a simulator addressed through CoreDevice rather than hardware.
    public var isSimulated: Bool { reality == "simulated" }

    /// Reads one entry of `result.devices`, or the `result` of `device info details`.
    ///
    /// Prefers the `properties` dictionary and falls back to the `hardwareProperties`,
    /// `deviceProperties`, and `connectionProperties` keys devicectl has deprecated, so output from
    /// older Xcode versions and from `--omit-deprecated-fields-in-json` both read.
    init?(json device: JSONValue, includeSimulators: Bool) {
        let hardware = device.value(at: "properties", "hardware") ?? device["hardwareProperties"]
        let connection = device.value(at: "properties", "connection") ?? device["connectionProperties"]
        let state = device.value(at: "properties", "state") ?? device["deviceProperties"]
        let reality = hardware?["reality"]?.stringValue
        guard includeSimulators || reality != "simulated" else { return nil }
        let identifier = device["identifier"]?.stringValue ?? ""
        let udid = hardware?["udid"]?.stringValue ?? identifier
        guard !udid.isEmpty else { return nil }
        let osVersion =
            device.value(at: "properties", "software", "osVersionNumber")
            ?? device.value(at: "deviceProperties", "osVersionNumber")
        self.init(
            udid: udid,
            identifier: identifier,
            name: state?["name"]?.stringValue ?? udid,
            platform: hardware?["platform"]?.stringValue ?? "iOS",
            osVersion: osVersion?["stringValue"]?.stringValue ?? osVersion?.stringValue,
            model: hardware?["marketingName"]?.stringValue ?? hardware?["productType"]?.stringValue,
            transport: connection?["transportType"]?.stringValue,
            isConnected: (connection?["state"]?.stringValue ?? connection?["tunnelState"]?.stringValue) == "connected",
            developerModeEnabled: Self.developerMode(state?["developerModeStatus"]),
            reality: reality
        )
    }

    /// New output nests the status (`{"enabled": {...}}`); older output is the bare word.
    private static func developerMode(_ status: JSONValue?) -> Bool? {
        if let word = status?.stringValue { return word == "enabled" }
        guard let object = status?.objectValue else { return nil }
        if object["enabled"] != nil { return true }
        if object["disabled"] != nil { return false }
        return nil
    }

    init(
        udid: String, identifier: String, name: String, platform: String, osVersion: String?, model: String?, transport: String?,
        isConnected: Bool, developerModeEnabled: Bool?, reality: String?
    ) {
        self.udid = udid
        self.identifier = identifier
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.model = model
        self.transport = transport
        self.isConnected = isConnected
        self.developerModeEnabled = developerModeEnabled
        self.reality = reality
    }
}

/// Everything `devicectl` can do to a device, plus port forwarding through `iproxy`.
///
/// Physical devices, and from Xcode 27 simulators (see `list(includeSimulators:)`), are addressed by
/// the identifier `devicectl --device` accepts: UDID, CoreDevice identifier, ECID, serial number, name,
/// or DNS name. Separate from ``SimulatorManager``: devicectl has no boot or erase for simulators and
/// cannot forward ports.
///
/// Operations are grouped across the `PhysicalIOSDevices+*.swift` files: information, processes,
/// capture and files, settings, simulation, pasteboard and notifications, and management. Results
/// with an observed JSON shape are typed; the rest return a ``DeviceCtlResponse``. A CoreDevice error
/// is thrown as ``MobileKitError/coreDeviceFailed(_:)`` with its code, so a caller can tell an
/// unsupported capability from a missing device. Operations that never end on their own return the
/// spawned process for the caller to stop.
public struct PhysicalIOSDeviceManager: Sendable {
    let shell: ShellContext
    let logger = Logger.forType(PhysicalIOSDeviceManager.self)

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    /// Physical devices; `connectedOnly` keeps the ones that can be driven now.
    ///
    /// - Parameter includeSimulators: Also return the simulators Xcode 27's devicectl lists, which
    ///   it can drive like hardware.
    public func list(
        connectedOnly: Bool = false,
        platform: String? = "iOS",
        includeSimulators: Bool = false
    ) async throws -> [PhysicalIOSDevice] {
        logger.debug("Listing CoreDevice devices")
        let output = try await ToolRunner.run(DeviceCtl(context: shell).listDevices().jsonOutput(), timeout: .seconds(20))
        let devices = Self.parseDevices(output.stdout, includeSimulators: includeSimulators).filter {
            (!connectedOnly || $0.isConnected) && (platform == nil || $0.platform == platform)
        }
        logger.debug("Listed CoreDevice devices", metadata: ["count": "\(devices.count)"])
        return devices
    }

    /// Parses `devicectl list devices --json-output`.
    ///
    /// Xcode 27's devicectl also lists simulators (`reality == "simulated"`); they are dropped unless
    /// `includeSimulators`. Older versions omit `reality` and list only hardware.
    public static func parseDevices(_ json: String, includeSimulators: Bool = false) -> [PhysicalIOSDevice] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
            let devices = root.value(at: "result", "devices")?.arrayValue
        else { return [] }
        return devices.compactMap { PhysicalIOSDevice(json: $0, includeSimulators: includeSimulators) }
    }

    // MARK: - Apps

    /// Installs an `.app` bundle. The result carries the installed app's `launchServicesIdentifier`,
    /// which ``CoreDeviceLaunchOptions`` accepts as `launchPersistentIdentifier`.
    @discardableResult
    public func install(appAt path: String, on udid: String, columns: CoreDeviceColumnOptions = .init()) async throws -> DeviceCtlResponse {
        logger.info("Installing app on device", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).install(appPath: path, device: udid, columns: columns),
            operation: "install.app", device: udid, timeout: .seconds(600))
        logger.info("Installed app on device", metadata: ["udid": "\(udid)"])
        return response
    }

    public func uninstall(bundleID: String, from udid: String) async throws {
        logger.info("Uninstalling app from device", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).uninstall(bundleID: bundleID, device: udid),
            operation: "uninstall.app", device: udid, timeout: .seconds(120))
        logger.info("Uninstalled app from device", metadata: ["udid": "\(udid)"])
    }

    /// Launches an app, terminating a running instance first unless `terminateExisting` is `false`.
    ///
    /// - Parameters:
    ///   - arguments: Passed to the app. They follow `--`, so values such as `-v` reach the app.
    ///   - environment: Sent as devicectl's `--environment-variables` object.
    ///   - startStopped: Launch suspended, waiting for a debugger.
    ///   - payloadURL: A URL for the app to open during launch.
    ///   - options: User, working directory, architecture, activation, display, and persistent identifier.
    /// - Returns: The launched process.
    @discardableResult
    public func launch(
        bundleID: String,
        on udid: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        terminateExisting: Bool = true,
        startStopped: Bool = false,
        payloadURL: String? = nil,
        options: CoreDeviceLaunchOptions = .init()
    ) async throws -> CoreDeviceLaunchedProcess {
        logger.info("Launching app on device", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).launch(
                bundleID: bundleID, device: udid, terminateExisting: terminateExisting, startStopped: startStopped,
                environment: environment, payloadURL: payloadURL, options: options, arguments: arguments),
            operation: "process.launch", device: udid, timeout: .seconds(120))
        guard let process = CoreDeviceLaunchedProcess.parse(response.result) else {
            throw MobileKitError.unexpectedOutput(tool: "devicectl device process launch", detail: "no process identifier in the result")
        }
        logger.info("Launched app on device", metadata: ["udid": "\(udid)", "pid": "\(process.processIdentifier)"])
        return process
    }

    /// The process id of a running app, matched on its `.app` executable path.
    public func runningProcessID(bundleID: String, on udid: String) async throws -> Int32? {
        let output = try await ToolRunner.run(DeviceCtl(context: shell).processes(device: udid).jsonOutput(), timeout: .seconds(20))
        return Self.processID(inProcessList: output.stdout, bundleID: bundleID)
    }

    /// devicectl reports processes by executable path, not bundle id; the app's `.app` name is
    /// conventionally the last bundle-id segment (`com.example.Foo` → `Foo.app`).
    static func processID(inProcessList json: String, bundleID: String) -> Int32? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
            let processes = root.value(at: "result", "runningProcesses")?.arrayValue,
            let name = bundleID.split(separator: ".").last
        else { return nil }
        return processes.lazy.compactMap(CoreDeviceProcess.parse).first { ($0.executable ?? "").contains("/\(name).app/") }?
            .processIdentifier
    }

    /// Terminates an app; an app that is not running is not an error.
    public func terminate(bundleID: String, on udid: String) async throws {
        guard let pid = try await runningProcessID(bundleID: bundleID, on: udid) else {
            logger.debug("App is not running, nothing to terminate", metadata: ["udid": "\(udid)"])
            return
        }
        logger.info("Terminating app on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
        try await ToolRunner.run(DeviceCtl(context: shell).signal("SIGKILL", pid: pid, device: udid), timeout: .seconds(30))
        logger.info("Terminated app on device", metadata: ["udid": "\(udid)", "pid": "\(pid)"])
    }

    // MARK: - Port forwarding

    /// Forwards `localPort` on this host to `devicePort` on the device over USB. The returned
    /// process runs until the caller tears it down.
    public func forwardPort(localPort: Int, devicePort: Int, udid: String) async throws -> any SpawnedProcess {
        logger.info("Forwarding port to device", metadata: ["udid": "\(udid)", "local": "\(localPort)", "device": "\(devicePort)"])
        let iproxy = IProxy(context: shell).forward(localPort: localPort, devicePort: devicePort, udid: udid)
        do {
            return try await iproxy.spawn(teardown: .graceful)
        } catch let error as ShellError {
            throw ToolRunner.map(error, argv: ["iproxy"] + iproxy.command().arguments)
        }
    }
}
