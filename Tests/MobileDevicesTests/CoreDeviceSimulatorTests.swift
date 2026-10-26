import Foundation
import MobileCore
import SwiftyShell
import Testing

@testable import MobileDevices

/// Runs the manager against a booted simulator through the real `devicectl` (Xcode 27 or later).
///
/// Off by default. Set `MOBILEKITS_DEVICECTL_SIMULATOR` to the UDID of a booted simulator you do not
/// mind changing: the tests set and then clear a simulated location and a status bar override, and
/// launch and terminate Settings. A launch retries when CoreDevice reports 10004, the simulator
/// race where an app exits before its process id can be read.
@Suite(
    "CoreDevice against a real simulator",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["MOBILEKITS_DEVICECTL_SIMULATOR"] != nil))
struct CoreDeviceSimulatorTests {
    private let udid = ProcessInfo.processInfo.environment["MOBILEKITS_DEVICECTL_SIMULATOR"] ?? ""
    private let manager = PhysicalIOSDeviceManager()

    @Test("The simulator is listed, addressable, and connected")
    func listed() async throws {
        let devices = try await manager.list(includeSimulators: true)
        let device = try #require(devices.first { $0.udid == udid })
        #expect(device.isSimulated)
        #expect(device.isConnected)
        #expect(try await manager.list().contains { $0.udid == udid } == false)
        let details = try await manager.details(of: udid)
        #expect(details.device.udid == udid)
        #expect(details.bootState == "booted")
    }

    @Test("Typed reads decode live output")
    func reads() async throws {
        let displays = try await manager.displays(on: udid)
        let primary = try #require(displays.primary)
        #expect((primary.nativeWidth ?? 0) > 0)
        #expect(try await manager.apps(on: udid, options: .init(includeAllApps: true)).isEmpty == false)
        #expect(try await manager.processes(on: udid).contains { $0.processIdentifier == 1 })
        #expect(["light", "dark"].contains(try await manager.appearance(of: udid).userInterfaceStyle ?? ""))
        #expect((try await manager.audio(of: udid).volume ?? -1) >= 0)
        #expect(try await manager.orientation(of: udid).isLocked != nil)
        #expect(try await manager.biometrics(on: udid).isEmpty == false)
        #expect(try await manager.locationScenarios(on: udid).isEmpty == false)
        #expect(try await manager.pasteboardInfo(on: udid).pasteboardName == "general")
        #expect(try await manager.hostAudioDevices().outputs.isEmpty == false)
        #expect(try await manager.isVoiceOverEnabled(on: udid) == false)
    }

    @Test("A capability the simulator lacks is a typed failure")
    func unsupported() async throws {
        let error = await #expect(throws: MobileKitError.self) { try await manager.lockState(of: udid) }
        guard case .coreDeviceFailed(let failure) = error else {
            Issue.record("expected a CoreDevice failure, got \(String(describing: error))")
            return
        }
        #expect(failure.isUnsupportedCapability)
        #expect(failure.capability == "Get Lock State")
    }

    @Test("A device that does not exist is a typed failure")
    func missingDevice() async throws {
        let error = await #expect(throws: MobileKitError.self) { try await manager.lockState(of: "no-such-device-for-mobile-kits") }
        guard case .coreDeviceFailed(let failure) = error else {
            Issue.record("expected a CoreDevice failure, got \(String(describing: error))")
            return
        }
        #expect(failure.isDeviceNotFound)
    }

    @Test("A screenshot is a PNG of the primary display")
    func screenshot() async throws {
        let data = try await manager.screenshot(on: udid)
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let path = PhysicalIOSDeviceManager.temporaryPath("kits_live", extension: "png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let described = try await manager.captureScreenshot(on: udid, to: path)
        #expect(described.path == path || described.path.hasSuffix(URL(fileURLWithPath: path).lastPathComponent))
        #expect((described.width ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("A western-hemisphere location is accepted and cleared")
    func location() async throws {
        try await manager.simulateLocation(latitude: 37.33, longitude: -122.03, on: udid)
        try await manager.clearSimulatedLocation(on: udid)
    }

    @Test("A status bar override is applied, read back, and cleared")
    func statusBar() async throws {
        try await manager.overrideStatusBar(.init(time: "9:41", batteryLevel: 100), on: udid)
        let state = try await manager.statusBar(on: udid)
        #expect(state.time?.hasPrefix("9:41") == true)
        try await manager.clearStatusBar(on: udid)
        #expect(try await manager.statusBar(on: udid).overrides.isEmpty)
    }

    @Test("An app launches with arguments that look like devicectl's, then terminates")
    func launchAndTerminate() async throws {
        var process: CoreDeviceLaunchedProcess?
        for _ in 0..<3 where process == nil {
            do {
                process = try await manager.launch(bundleID: "com.apple.Preferences", on: udid, arguments: ["-v", "--timeout", "1"])
            } catch MobileKitError.coreDeviceFailed(let failure) where failure.code == 10004 {
                continue
            }
        }
        #expect((try #require(process)).processIdentifier > 0)
        try await manager.terminate(bundleID: "com.apple.Preferences", on: udid)
    }
}
