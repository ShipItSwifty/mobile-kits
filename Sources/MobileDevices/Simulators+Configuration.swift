import Foundation
import MobileCore
import SwiftyShell
import XcrunKit

/// The interface style `simctl ui <udid> appearance` accepts.
public enum SimulatorAppearance: String, Sendable, CaseIterable {
    case light
    case dark
}

/// What `simctl privacy` does to a permission.
public enum SimulatorPrivacyAction: String, Sendable, CaseIterable {
    case grant
    case revoke
    case reset
}

extension SimulatorManager {
    // MARK: - Privacy

    /// Grants, revokes, or resets a privacy permission (`simctl privacy`).
    ///
    /// - Parameters:
    ///   - service: A simctl service name, e.g. `camera`, `location`, `photos`, or `all`.
    ///   - bundleID: The app; omit to apply the action to every app (valid for `reset`).
    public func privacy(
        _ action: SimulatorPrivacyAction,
        service: String,
        bundleID: String? = nil,
        on udid: String
    ) async throws {
        logger.info(
            "Changing simulator privacy",
            metadata: ["udid": "\(udid)", "action": "\(action.rawValue)", "service": "\(service)"])
        try await ToolRunner.run(
            Simctl(context: shell).privacy(udid, action: action.rawValue, service: service, bundleIdentifier: bundleID),
            timeout: .seconds(30)
        )
    }

    // MARK: - Location

    /// Sets the simulated location (`simctl location <udid> set <lat>,<lon>`).
    public func setLocation(latitude: Double, longitude: Double, on udid: String) async throws {
        logger.info("Setting simulator location", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(
            Simctl(context: shell).location(udid, action: "set", arguments: ["\(latitude),\(longitude)"]),
            timeout: .seconds(30)
        )
    }

    /// Clears the simulated location (`simctl location <udid> clear`).
    public func clearLocation(on udid: String) async throws {
        logger.info("Clearing simulator location", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(Simctl(context: shell).location(udid, action: "clear"), timeout: .seconds(30))
    }

    // MARK: - UI

    /// Switches between light and dark mode (`simctl ui <udid> appearance <value>`).
    public func setAppearance(_ appearance: SimulatorAppearance, on udid: String) async throws {
        logger.info("Setting simulator appearance", metadata: ["udid": "\(udid)", "appearance": "\(appearance.rawValue)"])
        try await ToolRunner.run(
            Simctl(context: shell).ui(udid, arguments: ["appearance", appearance.rawValue]), timeout: .seconds(30))
    }

    /// Opens a URL, routing it to the app that handles its scheme (`simctl openurl`).
    public func openURL(_ url: String, on udid: String) async throws {
        logger.info("Opening URL on simulator", metadata: ["udid": "\(udid)"])
        try await ToolRunner.run(Simctl(context: shell).openURL(udid, url), timeout: .seconds(30))
    }

    // MARK: - App inventory

    /// The raw `simctl listapps` output (a property list) for the apps installed on `udid`.
    public func listApps(on udid: String) async throws -> String {
        try await ToolRunner.run(Simctl(context: shell).listApps(udid), timeout: .seconds(30)).stdout
    }

    /// Bundle identifiers of every installed app, system apps included, sorted.
    ///
    /// Output that is not a property list dictionary yields `[]` rather than an error.
    public func installedAppBundleIDs(on udid: String) async throws -> [String] {
        logger.debug("Listing installed apps", metadata: ["udid": "\(udid)"])
        let ids = Self.bundleIdentifiers(fromListApps: try await listApps(on: udid))
        logger.debug("Listed installed apps", metadata: ["udid": "\(udid)", "count": "\(ids.count)"])
        return ids
    }

    /// Parses `simctl listapps`, which prints a plist (usually old-style) keyed by bundle id.
    static func bundleIdentifiers(fromListApps output: String) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), options: [], format: nil),
            let apps = plist as? [String: Any]
        else { return [] }
        return apps.keys.sorted()
    }
}
