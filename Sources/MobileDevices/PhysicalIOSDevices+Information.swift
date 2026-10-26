import DeviceCtlKit
import Foundation
import MobileCore

// `devicectl device info`: read-only queries. Operations with an observed result shape return a
// typed value; the others return the ``DeviceCtlResponse`` so nothing devicectl reports is lost.
extension PhysicalIOSDeviceManager {
    /// Hardware, software, connection, and capability details of one device.
    public func details(of udid: String) async throws -> CoreDeviceDetails {
        let response = try await perform(DeviceCtl(context: shell).details(device: udid), operation: "info.details", device: udid)
        guard let details = CoreDeviceDetails.parse(response.result) else {
            throw MobileKitError.unexpectedOutput(tool: "devicectl device info details", detail: "no device in the result")
        }
        return details
    }

    /// The apps installed on a device. Developer apps only unless `options` widens it.
    ///
    /// - Parameters:
    ///   - bundleID: Match one bundle identifier exactly.
    ///   - options: Include App Clips, removable or default apps, container paths, and app groups.
    ///   - filter: A text search, an NSPredicate, and a sort order applied by devicectl.
    public func apps(
        on udid: String,
        bundleID: String? = nil,
        options: CoreDeviceAppListOptions = .init(),
        filter: CoreDeviceFilterOptions = .init()
    ) async throws -> [CoreDeviceApp] {
        let response = try await perform(
            DeviceCtl(context: shell).apps(device: udid, bundleID: bundleID, options: options, filter: filter),
            operation: "info.apps", device: udid)
        return (response.result["apps"]?.arrayValue ?? []).compactMap(CoreDeviceApp.parse)
    }

    /// The processes running on a device.
    public func processes(on udid: String, filter: CoreDeviceFilterOptions = .init()) async throws -> [CoreDeviceProcess] {
        let response = try await perform(
            DeviceCtl(context: shell).processes(device: udid, filter: filter), operation: "info.processes", device: udid)
        return (response.result["runningProcesses"]?.arrayValue ?? []).compactMap(CoreDeviceProcess.parse)
    }

    /// A device's displays, whose unique ids ``captureScreenshot(on:to:displayUniqueID:)`` and
    /// ``recordScreen(on:to:duration:codec:maskPolicy:displayUniqueID:)`` take.
    public func displays(on udid: String) async throws -> CoreDeviceDisplays {
        let response = try await perform(DeviceCtl(context: shell).displays(device: udid), operation: "info.displays", device: udid)
        return CoreDeviceDisplays.parse(response.result)
    }

    /// Files in a domain on a device.
    ///
    /// - Parameters:
    ///   - domain: An app data container, an app group container, a temporary directory, or crash logs.
    ///   - username: The user to target; only relevant for some domains.
    ///   - subdirectory: A directory within the domain; the root by default.
    ///   - recurse: Descend into subdirectories; devicectl does by default.
    public func files(
        on udid: String,
        domain: CoreDeviceFileDomain,
        username: String? = nil,
        subdirectory: String? = nil,
        recurse: Bool? = nil,
        filter: CoreDeviceFilterOptions = .init()
    ) async throws -> DeviceCtlResponse {
        try await perform(
            DeviceCtl(context: shell).files(
                device: udid, domain: domain, username: username, subdirectory: subdirectory, recurse: recurse, filter: filter),
            operation: "info.files", device: udid)
    }

    /// Asks the device to render an installed app's icon and, with `destination`, writes the PNG there.
    ///
    /// The device returns only the sizes it supports, so the result describes what it rendered.
    public func appIcon(
        on udid: String,
        bundleID: String? = nil,
        appPath: String? = nil,
        allowPlaceholder: Bool? = nil,
        width: Double? = nil,
        height: Double? = nil,
        scale: Double? = nil,
        destination: String? = nil
    ) async throws -> CoreDeviceAppIcon {
        let response = try await perform(
            DeviceCtl(context: shell).appIcon(
                device: udid, bundleID: bundleID, appPath: appPath, allowPlaceholder: allowPlaceholder, width: width, height: height,
                scale: scale, destination: destination),
            operation: "info.appIcon", device: udid)
        return CoreDeviceAppIcon.parse(response.result, destination: destination)
    }

    /// The state of the active resizable app session. Fails when no session is running.
    public func appResizeState(on udid: String) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).appResizeInfo(device: udid), operation: "info.appResize", device: udid)
    }

    /// The interface style, text size, and accessibility display settings.
    public func appearance(of udid: String) async throws -> CoreDeviceAppearance {
        let response = try await perform(DeviceCtl(context: shell).appearanceInfo(device: udid), operation: "info.appearance", device: udid)
        return CoreDeviceAppearance.parse(response.result)
    }

    /// The audio output and input routes and the volume.
    public func audio(of udid: String) async throws -> CoreDeviceAudioState {
        let response = try await perform(DeviceCtl(context: shell).audioInfo(device: udid), operation: "info.audio", device: udid)
        return CoreDeviceAudioState.parse(response.result)
    }

    /// The identifiers needed to AuthList a device with TATSU.
    public func authListing(of udid: String) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).authListing(device: udid), operation: "info.authListing", device: udid)
    }

    /// The developer disk image services on a device.
    ///
    /// - Parameter autoMountDDIs: Check and update the mounted DDI first, which devicectl does by
    ///   default and which changes the device. Pass `false` to read the current state only.
    public func ddiServices(of udid: String, autoMountDDIs: Bool? = nil) async throws -> DeviceCtlResponse {
        try await perform(
            DeviceCtl(context: shell).ddiServices(device: udid, autoMountDDIs: autoMountDDIs),
            operation: "info.ddiServices", device: udid, timeout: .seconds(300))
    }

    /// Whether a device is locked. Throws an unsupported-capability failure on a simulator.
    public func lockState(of udid: String) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).lockState(device: udid), operation: "info.lockState", device: udid)
    }

    /// The host path of a device's data folder, mounting its file system when needed.
    public func mountpoint(of udid: String) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).mountpoint(device: udid), operation: "info.mountpoint", device: udid)
    }

    /// Whether StandBy is showing: `unavailable` for a device that is not in a StandBy configuration.
    public func standbyState(of udid: String) async throws -> String? {
        let response = try await perform(DeviceCtl(context: shell).standbyInfo(device: udid), operation: "info.standby", device: udid)
        return response.result["state"]?.stringValue
    }

    /// Whether VoiceOver is enabled.
    public func isVoiceOverEnabled(on udid: String) async throws -> Bool {
        let response = try await perform(DeviceCtl(context: shell).voiceOverInfo(device: udid), operation: "info.voiceover", device: udid)
        return response.result["enabled"]?.boolValue ?? false
    }

    /// The orientation and whether rotation is locked.
    public func orientation(of udid: String) async throws -> CoreDeviceOrientationState {
        let response = try await perform(DeviceCtl(context: shell).orientation(device: udid), operation: "orientation.get", device: udid)
        return CoreDeviceOrientationState.parse(response.result)
    }
}
