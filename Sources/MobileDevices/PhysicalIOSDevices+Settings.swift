import DeviceCtlKit
import Foundation
import MobileCore
import SwiftyShell

// `devicectl device settings`, `orientation`, `appResize`, and device-level actions. Every operation
// here changes the device.
extension PhysicalIOSDeviceManager {
    // MARK: - Settings

    /// Changes the interface style, look and feel, text size, or accessibility display settings.
    /// Fields of `settings` that are `nil` are left alone.
    public func setAppearance(_ settings: CoreDeviceAppearanceSettings, on udid: String) async throws {
        logger.info("Setting device appearance", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).appearance(settings, device: udid), operation: "settings.appearance", device: udid)
        logger.info("Set device appearance", metadata: ["udid": "\(udid)"])
    }

    /// Sets the light or dark interface style.
    public func setAppearance(_ mode: CoreDeviceAppearanceMode, on udid: String) async throws {
        try await setAppearance(CoreDeviceAppearanceSettings(mode: mode), on: udid)
    }

    /// Sets the audio routes and volume. Routes are `systemDefault` or an id from ``hostAudioDevices()``.
    ///
    /// - Parameter volume: 0 to 100.
    public func setAudio(output: String? = nil, input: String? = nil, volume: Int? = nil, on udid: String) async throws {
        logger.info("Setting device audio", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).audio(output: output, input: input, volume: volume, device: udid),
            operation: "settings.audio", device: udid)
        logger.info("Set device audio", metadata: ["udid": "\(udid)"])
    }

    /// Reports biometric enrolment, or enables or disables every supported biometric.
    ///
    /// - Returns: Each biometric type and whether it is enrolled, as devicectl reports it.
    @discardableResult
    public func biometrics(_ action: CoreDeviceBiometricsAction = .query, on udid: String) async throws -> [CoreDeviceBiometric] {
        logger.info("Running device biometrics settings", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).biometrics(action, device: udid), operation: "settings.biometrics", device: udid)
        return CoreDeviceBiometric.parse(response.result)
    }

    /// Shows or hides StandBy. With `duration`, devicectl keeps it presented that many seconds and
    /// then dismisses it, which behaves the same on devices that sustain StandBy without a client.
    public func setStandby(_ action: CoreDeviceStandbyAction, duration: Double? = nil, on udid: String) async throws {
        logger.info("Setting device StandBy", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).standby(action, duration: duration, device: udid),
            operation: "settings.standby", device: udid, timeout: .seconds((duration ?? 0).rounded(.up) + 60))
        logger.info("Set device StandBy", metadata: ["udid": "\(udid)"])
    }

    /// Enables or disables VoiceOver.
    public func setVoiceOver(enabled: Bool, on udid: String) async throws {
        logger.info("Setting device VoiceOver", metadata: ["udid": "\(udid)", "enabled": "\(enabled)"])
        try await perform(
            DeviceCtl(context: shell).voiceOver(enabled: enabled, device: udid), operation: "settings.voiceover", device: udid)
        logger.info("Set device VoiceOver", metadata: ["udid": "\(udid)"])
    }

    /// Restores a device to factory settings, erasing all user content and files.
    ///
    /// **Destructive and irreversible.** Nothing in this package calls it; a caller must ask for it.
    public func resetDevice(_ udid: String) async throws {
        logger.info("Resetting device to factory settings", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).resetDevice(device: udid), operation: "settings.reset", device: udid, timeout: .seconds(300))
        logger.info("Reset device to factory settings", metadata: ["udid": "\(udid)"])
    }

    // MARK: - Orientation

    /// Sets the orientation.
    public func setOrientation(_ orientation: CoreDeviceOrientation, on udid: String) async throws {
        logger.info("Setting device orientation", metadata: ["udid": "\(udid)", "orientation": "\(orientation.rawValue)"])
        try await perform(
            DeviceCtl(context: shell).setOrientation(orientation, device: udid), operation: "orientation.set", device: udid)
        logger.info("Set device orientation", metadata: ["udid": "\(udid)"])
    }

    /// Rotates relative to the current orientation.
    public func rotate(_ direction: CoreDeviceRotationDirection, on udid: String) async throws {
        logger.info("Rotating device", metadata: ["udid": "\(udid)", "direction": "\(direction.rawValue)"])
        try await perform(DeviceCtl(context: shell).rotate(direction, device: udid), operation: "orientation.rotate", device: udid)
        logger.info("Rotated device", metadata: ["udid": "\(udid)"])
    }

    // MARK: - Resizable app sessions

    /// Adjusts the active resizable app session.
    ///
    /// - Parameter preferredSize: `<width>x<height>`, such as `800x600`.
    public func setAppResize(preferredSize: String, cornerRadius: Double? = nil, on udid: String) async throws {
        logger.info("Adjusting resizable app session", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).setAppResize(preferredSize: preferredSize, cornerRadius: cornerRadius, device: udid),
            operation: "appResize.set", device: udid)
        logger.info("Adjusted resizable app session", metadata: ["udid": "\(udid)"])
    }

    /// Starts a resizable app session by moving the frontmost apps to a resizable display. The session
    /// lasts until ``stopAppResize(_:timeout:)``.
    public func startAppResize(
        preferredSize: String? = nil,
        cornerRadius: Double? = nil,
        on udid: String
    ) async throws -> any SpawnedProcess {
        try await spawn(
            DeviceCtl(context: shell).startAppResize(preferredSize: preferredSize, cornerRadius: cornerRadius, device: udid),
            operation: "appResize.start", device: udid)
    }

    /// Streams resizability state changes until ``stopAppResize(_:timeout:)``. The updates arrive on
    /// the process's `standardOutput`, which devicectl does not promise to keep stable.
    public func observeAppResize(on udid: String) async throws -> any SpawnedProcess {
        try await spawn(DeviceCtl(context: shell).observeAppResize(device: udid), operation: "appResize.observe", device: udid)
    }

    /// Interrupts a session ``startAppResize(preferredSize:cornerRadius:on:)`` or
    /// ``observeAppResize(on:)`` started; ending ``startAppResize(preferredSize:cornerRadius:on:)``'s
    /// process ends the session.
    public func stopAppResize(_ process: any SpawnedProcess, timeout: Duration = .seconds(15)) async throws {
        _ = try await stop(process, operation: "appResize", timeout: timeout)
    }

    // MARK: - Device actions

    /// Reboots a device.
    ///
    /// - Parameters:
    ///   - style: A full reboot unless `userspace`.
    ///   - waitForDevice: Wait for the device to come back; only for physically connected devices.
    public func reboot(
        _ udid: String,
        style: CoreDeviceRebootStyle? = nil,
        waitForDevice: Bool = false,
        timeout: Duration = .seconds(300)
    ) async throws {
        logger.info("Rebooting device", metadata: ["udid": "\(udid)", "wait": "\(waitForDevice)"])
        try await perform(
            DeviceCtl(context: shell).reboot(style: style, waitForDevice: waitForDevice, device: udid),
            operation: "reboot", device: udid, timeout: timeout)
        logger.info("Rebooted device", metadata: ["udid": "\(udid)"])
    }

    /// Changes the name a device shows.
    public func rename(_ udid: String, to name: String) async throws {
        logger.info("Renaming device", metadata: ["udid": "\(udid)"])
        try await perform(DeviceCtl(context: shell).rename(to: name, device: udid), operation: "rename", device: udid)
        logger.info("Renamed device", metadata: ["udid": "\(udid)"])
    }

    /// Gathers a sysdiagnose from a device and returns devicectl's report of where it was placed.
    ///
    /// - Parameters:
    ///   - destination: A host directory; a unique temporary directory by default.
    ///   - gatherFullLogs: Ask for full logs, which makes the archive much larger.
    public func sysdiagnose(
        of udid: String,
        destination: String? = nil,
        gatherFullLogs: Bool = false,
        timeout: Duration = .seconds(900)
    ) async throws -> DeviceCtlResponse {
        logger.info("Gathering device sysdiagnose", metadata: ["udid": "\(udid)"])
        let run = try await performWritingJSONFile(
            DeviceCtl(context: shell).sysdiagnose(device: udid, destination: destination, gatherFullLogs: gatherFullLogs),
            operation: "sysdiagnose", device: udid, timeout: timeout)
        logger.info("Gathered device sysdiagnose", metadata: ["udid": "\(udid)"])
        return run.response
    }
}
