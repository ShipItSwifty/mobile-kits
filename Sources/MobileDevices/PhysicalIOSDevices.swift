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
    /// `wired`, `localNetwork`, ….
    public var transport: String?
    /// Whether a CoreDevice tunnel is up, i.e. the device can be driven right now.
    public var isConnected: Bool
    public var developerModeEnabled: Bool?

    public var id: String { udid }
}

/// Inventory, app management, and port forwarding for physical iOS devices through `devicectl`
/// and `iproxy`. Separate from ``SimulatorManager``: devicectl addresses devices differently, has no
/// erase or boot, and cannot forward ports.
public struct PhysicalIOSDeviceManager: Sendable {
    private let shell: ShellContext
    private let logger = Logger.forType(PhysicalIOSDeviceManager.self)

    public init(shell: ShellContext = .init()) {
        self.shell = shell
    }

    /// Physical devices; `connectedOnly` keeps the ones that can be driven now.
    public func list(connectedOnly: Bool = false, platform: String? = "iOS") async throws -> [PhysicalIOSDevice] {
        let output = try await ToolRunner.run(DeviceCtl(context: shell).listDevices().jsonOutput(), timeout: .seconds(20))
        return Self.parseDevices(output.stdout).filter {
            (!connectedOnly || $0.isConnected) && (platform == nil || $0.platform == platform)
        }
    }

    /// Parses `devicectl list devices --json-output`.
    ///
    /// Xcode 27's devicectl also lists simulators (`hardwareProperties.reality == "simulated"`);
    /// they are dropped here. Older versions omit `reality` and list only hardware.
    public static func parseDevices(_ json: String) -> [PhysicalIOSDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let devices = result["devices"] as? [[String: Any]]
        else { return [] }
        return devices.compactMap { device in
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            guard (hardware["reality"] as? String ?? "physical") != "simulated" else { return nil }
            let identifier = device["identifier"] as? String ?? ""
            let udid = hardware["udid"] as? String ?? identifier
            guard !udid.isEmpty else { return nil }
            return PhysicalIOSDevice(
                udid: udid,
                identifier: identifier,
                name: properties["name"] as? String ?? udid,
                platform: hardware["platform"] as? String ?? "iOS",
                osVersion: properties["osVersionNumber"] as? String,
                model: hardware["marketingName"] as? String ?? hardware["productType"] as? String,
                transport: connection["transportType"] as? String,
                isConnected: connection["tunnelState"] as? String == "connected",
                developerModeEnabled: (properties["developerModeStatus"] as? String).map { $0 == "enabled" }
            )
        }
    }

    // MARK: - Apps

    public func install(appAt path: String, on udid: String) async throws {
        logger.info("Installing app on device", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(DeviceCtl(context: shell).install(appPath: path, device: udid), timeout: .seconds(600))
    }

    public func uninstall(bundleID: String, from udid: String) async throws {
        try await ToolRunner.run(DeviceCtl(context: shell).uninstall(bundleID: bundleID, device: udid), timeout: .seconds(120))
    }

    /// Launches an app, terminating a running instance first.
    public func launch(
        bundleID: String,
        on udid: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        try await ToolRunner.run(
            DeviceCtl(context: shell).launch(
                bundleID: bundleID, device: udid, terminateExisting: true, environment: environment, arguments: arguments),
            timeout: .seconds(120)
        )
    }

    /// The process id of a running app, matched on its `.app` executable path.
    public func runningProcessID(bundleID: String, on udid: String) async throws -> Int32? {
        let output = try await ToolRunner.run(DeviceCtl(context: shell).processes(device: udid).jsonOutput(), timeout: .seconds(20))
        return Self.processID(inProcessList: output.stdout, bundleID: bundleID)
    }

    /// devicectl reports processes by executable path, not bundle id; the app's `.app` name is
    /// conventionally the last bundle-id segment (`com.example.Foo` → `Foo.app`).
    static func processID(inProcessList json: String, bundleID: String) -> Int32? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let processes = result["runningProcesses"] as? [[String: Any]],
            let name = bundleID.split(separator: ".").last
        else { return nil }
        return processes.lazy.compactMap { process -> Int32? in
            guard let pid = process["processIdentifier"] as? Int,
                (process["executable"] as? String ?? "").contains("/\(name).app/")
            else { return nil }
            return Int32(pid)
        }.first
    }

    /// Terminates an app; an app that is not running is not an error.
    public func terminate(bundleID: String, on udid: String) async throws {
        guard let pid = try await runningProcessID(bundleID: bundleID, on: udid) else { return }
        try await ToolRunner.run(DeviceCtl(context: shell).signal("SIGKILL", pid: pid, device: udid), timeout: .seconds(30))
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
