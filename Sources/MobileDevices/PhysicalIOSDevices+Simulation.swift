import DeviceCtlKit
import Foundation
import MobileCore

// `devicectl device simulate`: locations, status bar overrides, and biometric events. These work on
// hardware and, in Xcode 27, on simulators; a device that lacks a capability reports
// ``CoreDeviceFailure/isUnsupportedCapability``.
extension PhysicalIOSDeviceManager {
    // MARK: - Location

    /// Simulates a fixed location until ``clearSimulatedLocation(on:)``.
    public func simulateLocation(latitude: Double, longitude: Double, on udid: String) async throws {
        logger.info("Simulating device location", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).simulateLocation(latitude: latitude, longitude: longitude, device: udid),
            operation: "simulate.location.coordinate", device: udid)
        logger.info("Simulated device location", metadata: ["udid": "\(udid)"])
    }

    /// Stops any location simulation and returns the device to its real location.
    public func clearSimulatedLocation(on udid: String) async throws {
        logger.info("Clearing simulated device location", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).clearSimulatedLocation(device: udid), operation: "simulate.location.clear", device: udid)
        logger.info("Cleared simulated device location", metadata: ["udid": "\(udid)"])
    }

    /// The device's pre-defined location scenarios, whose names ``simulateLocationScenario(_:on:)`` takes.
    public func locationScenarios(on udid: String) async throws -> [CoreDeviceLocationScenario] {
        let response = try await perform(
            DeviceCtl(context: shell).listLocationScenarios(device: udid), operation: "simulate.location.list", device: udid)
        return CoreDeviceLocationScenario.parse(response.result)
    }

    /// Moves the device along waypoints at a speed, or along a route file.
    public func simulateLocationRoute(_ route: CoreDeviceLocationRoute, on udid: String) async throws {
        logger.info("Simulating device location route", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).simulateLocationRoute(route, device: udid),
            operation: "simulate.location.route", device: udid)
        logger.info("Started device location route", metadata: ["udid": "\(udid)"])
    }

    /// Plays a pre-defined scenario by name, or a scenario file inside the simulator runtime.
    public func simulateLocationScenario(_ nameOrFile: String, on udid: String) async throws {
        logger.info("Simulating device location scenario", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).simulateLocationScenario(nameOrFile, device: udid),
            operation: "simulate.location.scenario", device: udid)
        logger.info("Started device location scenario", metadata: ["udid": "\(udid)"])
    }

    // MARK: - Status bar

    /// Overrides status bar indicators. Overrides are cosmetic and last until ``clearStatusBar(on:)``.
    public func overrideStatusBar(_ override: CoreDeviceStatusBarOverride, on udid: String) async throws {
        logger.info("Overriding device status bar", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).overrideStatusBar(override, device: udid),
            operation: "simulate.statusBar.override", device: udid)
        logger.info("Overrode device status bar", metadata: ["udid": "\(udid)"])
    }

    /// Applies a named status bar configuration, such as the classic 9:41 screenshot setup.
    public func applyStatusBarPreset(_ preset: CoreDeviceStatusBarPreset, on udid: String) async throws {
        logger.info("Applying device status bar preset", metadata: ["udid": "\(udid)", "preset": "\(preset.rawValue)"])
        try await perform(
            DeviceCtl(context: shell).applyStatusBarPreset(preset, device: udid),
            operation: "simulate.statusBar.preset", device: udid)
        logger.info("Applied device status bar preset", metadata: ["udid": "\(udid)"])
    }

    /// Removes every status bar override.
    public func clearStatusBar(on udid: String) async throws {
        logger.info("Clearing device status bar overrides", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).clearStatusBar(device: udid), operation: "simulate.statusBar.clear", device: udid)
        logger.info("Cleared device status bar overrides", metadata: ["udid": "\(udid)"])
    }

    /// The status bar overrides currently applied.
    public func statusBar(on udid: String) async throws -> CoreDeviceStatusBarState {
        let response = try await perform(
            DeviceCtl(context: shell).showStatusBar(device: udid), operation: "simulate.statusBar.show", device: udid)
        return CoreDeviceStatusBarState.parse(response.result)
    }

    // MARK: - Biometrics

    /// Presents a biometric match or failure for every supported biometric type. Biometrics must be
    /// enrolled; see ``biometrics(_:on:)``.
    public func simulateBiometrics(_ outcome: CoreDeviceBiometricOutcome, on udid: String) async throws {
        logger.info("Simulating device biometric event", metadata: ["udid": "\(udid)", "outcome": "\(outcome.rawValue)"])
        try await perform(
            DeviceCtl(context: shell).simulateBiometrics(outcome, device: udid), operation: "simulate.biometrics", device: udid)
        logger.info("Simulated device biometric event", metadata: ["udid": "\(udid)"])
    }
}
