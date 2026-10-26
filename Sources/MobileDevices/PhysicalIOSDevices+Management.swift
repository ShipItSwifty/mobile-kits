import DeviceCtlKit
import Foundation
import MobileCore

// Profiles, pairings, and the host side of CoreDevice: `devicectl device profile`, `device pairings`,
// `list`, `manage`, and `diagnose`.
extension PhysicalIOSDeviceManager {
    // MARK: - Profiles

    /// Installs provisioning (`.mobileprovision`) or configuration (`.mobileconfig`) profiles in one
    /// batch, each validated first.
    ///
    /// - Parameters:
    ///   - type: Forces the type; devicectl detects it from the file extension otherwise.
    ///   - replaceExisting: Replace a profile with the same identifier; devicectl does by default.
    @discardableResult
    public func installProfiles(
        at paths: [String],
        on udid: String,
        type: CoreDeviceProfileType? = nil,
        replaceExisting: Bool? = nil
    ) async throws -> DeviceCtlResponse {
        logger.info("Installing profiles on device", metadata: ["udid": "\(udid)", "count": "\(paths.count)"])
        let response = try await perform(
            DeviceCtl(context: shell).installProfiles(paths, device: udid, type: type, replaceExisting: replaceExisting),
            operation: "profile.install", device: udid)
        logger.info("Installed profiles on device", metadata: ["udid": "\(udid)"])
        return response
    }

    /// The profiles installed on a device.
    public func profiles(
        on udid: String,
        type: CoreDeviceProfileType? = nil,
        filter: CoreDeviceFilterOptions = .init()
    ) async throws -> DeviceCtlResponse {
        try await perform(
            DeviceCtl(context: shell).listProfiles(device: udid, type: type, filter: filter), operation: "profile.list", device: udid)
    }

    /// Removes profiles by provisioning-profile UUID or configuration-profile payload identifier.
    ///
    /// - Parameter forceRemoval: Succeed even when the profile is not on the device.
    public func removeProfiles(
        _ identifiers: [String],
        from udid: String,
        type: CoreDeviceProfileType? = nil,
        forceRemoval: Bool = false
    ) async throws {
        logger.info("Removing profiles from device", metadata: ["udid": "\(udid)", "count": "\(identifiers.count)"])
        try await perform(
            DeviceCtl(context: shell).removeProfiles(identifiers, device: udid, type: type, forceRemoval: forceRemoval),
            operation: "profile.remove", device: udid)
        logger.info("Removed profiles from device", metadata: ["udid": "\(udid)"])
    }

    /// Validates profiles without installing them. Local; needs no device.
    public func validateProfiles(at paths: [String], type: CoreDeviceProfileType? = nil) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).validateProfiles(paths, type: type), operation: "profile.validate")
    }

    // MARK: - Pairing

    /// Pairs the host with a device CoreDevice discovered. May prompt on the device.
    public func pair(_ udid: String, columns: CoreDeviceColumnOptions = .init()) async throws {
        logger.info("Pairing with device", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).pairDevice(device: udid, columns: columns),
            operation: "manage.pair", device: udid, timeout: .seconds(120))
        logger.info("Paired with device", metadata: ["udid": "\(udid)"])
    }

    /// Unpairs a manually paired device.
    public func unpair(_ udid: String, columns: CoreDeviceColumnOptions = .init()) async throws {
        logger.info("Unpairing device", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).unpairDevice(device: udid, columns: columns), operation: "manage.unpair", device: udid)
        logger.info("Unpaired device", metadata: ["udid": "\(udid)"])
    }

    /// The devices paired with a phone or watch.
    public func pairings(of udid: String, filter: CoreDeviceFilterOptions = .init()) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).listPairings(device: udid, filter: filter), operation: "pairings.list", device: udid)
    }

    /// Pairs a phone with one or more watches.
    public func pairWatches(phone: String, watches: [String]) async throws {
        logger.info("Pairing watches with phone", metadata: ["phone": "\(phone)", "count": "\(watches.count)"])
        try await perform(
            DeviceCtl(context: shell).pairWatches(phone: phone, watches: watches),
            operation: "pairings.pair", device: phone, timeout: .seconds(300))
        logger.info("Paired watches with phone", metadata: ["phone": "\(phone)"])
    }

    /// Makes an existing phone and watch pairing the active one.
    public func setActivePairing(phone: String, watch: String) async throws {
        logger.info("Activating phone and watch pairing", metadata: ["phone": "\(phone)", "watch": "\(watch)"])
        try await perform(
            DeviceCtl(context: shell).setActivePairing(phone: phone, watch: watch), operation: "pairings.setActive", device: phone)
        logger.info("Activated phone and watch pairing", metadata: ["phone": "\(phone)"])
    }

    /// Unpairs a phone from one or more watches.
    public func unpairWatches(phone: String, watches: [String]) async throws {
        logger.info("Unpairing watches from phone", metadata: ["phone": "\(phone)", "count": "\(watches.count)"])
        try await perform(
            DeviceCtl(context: shell).unpairWatches(phone: phone, watches: watches), operation: "pairings.unpair", device: phone)
        logger.info("Unpaired watches from phone", metadata: ["phone": "\(phone)"])
    }

    // MARK: - Host

    /// The audio input and output devices on this Mac, whose ids ``setAudio(output:input:volume:on:)`` takes.
    public func hostAudioDevices() async throws -> CoreDeviceHostAudioDevices {
        let response = try await perform(DeviceCtl(context: shell).listAudioDevices(), operation: "list.audioDevices")
        return CoreDeviceHostAudioDevices.parse(response.result)
    }

    /// The plugins devicectl and CoreDeviceService loaded.
    public func plugins() async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).listPlugins(), operation: "list.plugins")
    }

    /// The developer disk image CoreDevice would use for `platform`, or for every platform when `nil`.
    public func preferredDDI(platform: String? = nil) async throws -> DeviceCtlResponse {
        try await perform(DeviceCtl(context: shell).listPreferredDDI(platform: platform), operation: "list.preferredDDI")
    }

    /// Removes every developer disk image in `/Library/Developer/DeveloperDiskImages`. Changes the host.
    public func cleanHostDDIs() async throws {
        logger.info("Removing host developer disk images")
        try await perform(DeviceCtl(context: shell).manageDDIsClean(), operation: "manage.ddis.clean", timeout: .seconds(300))
        logger.info("Removed host developer disk images")
    }

    /// Updates the developer disk images installed on this Mac. Changes the host.
    ///
    /// - Parameters:
    ///   - sourceDirectories: Absolute paths of directories of DDIs to install instead of Xcode's.
    ///   - clean: Empty `/Library/Developer/DeveloperDiskImages` first.
    ///   - includeCoreDevice: Consider `/Library/Developer/CoreDevice/CandidateDDIs`.
    ///   - includeXcode: Consider the selected Xcode's DDIs.
    public func updateHostDDIs(
        sourceDirectories: [String] = [],
        clean: Bool? = nil,
        includeCoreDevice: Bool? = nil,
        includeXcode: Bool? = nil
    ) async throws {
        logger.info("Updating host developer disk images")
        try await perform(
            DeviceCtl(context: shell).manageDDIsUpdate(
                sourceDirectories: sourceDirectories, clean: clean, includeCoreDevice: includeCoreDevice, includeXcode: includeXcode),
            operation: "manage.ddis.update", timeout: .seconds(900))
        logger.info("Updated host developer disk images")
    }

    /// Registers CoreDevice's logging profile on this Mac. The user then activates it in System Settings.
    public func registerLoggingProfile() async throws {
        logger.info("Registering the CoreDevice logging profile")
        try await perform(DeviceCtl(context: shell).registerLoggingProfile(), operation: "manage.loggingProfile.register")
        logger.info("Registered the CoreDevice logging profile")
    }

    /// Gathers host and device diagnostics into a ZIP archive and returns devicectl's report of it.
    ///
    /// Never reveals the archive in Finder, so it is safe headless.
    ///
    /// - Parameters:
    ///   - archiveDestination: Where to write the ZIP; `/tmp/devicectl_diagnose_<timestamp>.zip` by default.
    ///   - archive: Pass `false` to leave the collected files uncompressed.
    ///   - includeHostSysdiagnose: Include the slower host sysdiagnose.
    ///   - keepTempDirectory: Keep the working directory after archiving.
    ///   - timeout: devicectl itself waits up to an hour.
    public func diagnose(
        archiveDestination: String? = nil,
        archive: Bool? = nil,
        includeHostSysdiagnose: Bool? = nil,
        keepTempDirectory: Bool = false,
        timeout: Duration = .seconds(3700)
    ) async throws -> DeviceCtlResponse {
        logger.info("Gathering CoreDevice diagnostics")
        let run = try await performWritingJSONFile(
            DeviceCtl(context: shell).diagnose(
                finder: false, keepTempDirectory: keepTempDirectory, archiveDestination: archiveDestination, archive: archive,
                includeHostSysdiagnose: includeHostSysdiagnose),
            operation: "diagnose", timeout: timeout)
        logger.info("Gathered CoreDevice diagnostics")
        return run.response
    }
}
