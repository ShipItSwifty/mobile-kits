import Foundation
import MobileCore
import SwiftyShell
import Testing

@testable import MobileDevices

/// Decodes `devicectl --json-output` documents captured from Xcode 27.2's devicectl (651.31) against
/// an iOS 27.2 simulator, so the models are checked against what the tool writes and fail first when
/// it changes. See `Fixtures/real/README.md` for how each was captured.
enum DeviceCtlFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/real/devicectl")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("\(name).json"), encoding: .utf8)
    }

    /// The document's `result`, requiring the run to have succeeded.
    static func result(_ name: String) throws -> JSONValue {
        let output = ShellOutput(stdout: try text(name), exitCode: 0)
        return try DeviceCtlResponse.decode(json: output.stdout, output: output, argv: ["devicectl"]).result
    }

    /// The error a failed run raises.
    static func failure(_ name: String) throws -> CoreDeviceFailure {
        let output = ShellOutput(stdout: try text(name), exitCode: 1)
        do {
            _ = try DeviceCtlResponse.decode(json: output.stdout, output: output, argv: ["devicectl", name])
        } catch MobileKitError.coreDeviceFailed(let failure) {
            return failure
        }
        throw MobileKitError.unexpectedOutput(tool: "test", detail: "\(name) did not fail")
    }

    static let simulator = "11111111-2222-3333-4444-555555555555"
}

@Suite("CoreDevice real output: devices")
struct CoreDeviceDeviceOutputTests {
    @Test("Hardware is listed, simulators only on request")
    func listsDevices() throws {
        let json = try DeviceCtlFixture.text("list-devices")
        let hardware = PhysicalIOSDeviceManager.parseDevices(json)
        #expect(hardware.map(\.name) == ["Test iPhone"])
        let phone = try #require(hardware.first)
        #expect(phone.udid == "00008120-000000000000001E")
        #expect(phone.identifier == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(phone.reality == "physical")
        #expect(phone.isSimulated == false)
        #expect(phone.transport == "localNetwork")
        #expect(phone.isConnected == false)
        #expect(phone.developerModeEnabled == true)

        let all = PhysicalIOSDeviceManager.parseDevices(json, includeSimulators: true)
        #expect(all.map(\.name) == ["iPhone 18 Pro Max", "iPhone 17", "Test iPhone"])
        let booted = try #require(all.first { $0.udid == DeviceCtlFixture.simulator })
        #expect(booted.isSimulated)
        #expect(booted.isConnected)
        #expect(booted.transport == "sameMachine")
        #expect(booted.osVersion == "27.2")
        #expect(booted.model == "iPhone 18 Pro Max")
        #expect(all.first { $0.name == "iPhone 17" }?.isConnected == false)
    }

    @Test("Output without the deprecated keys reads the same as output with them")
    func omitDeprecatedFields() throws {
        let legacy = PhysicalIOSDeviceManager.parseDevices(try DeviceCtlFixture.text("list-devices"), includeSimulators: true)
        let current = PhysicalIOSDeviceManager.parseDevices(
            try DeviceCtlFixture.text("list-devices-omit-deprecated"), includeSimulators: true)
        #expect(current == legacy)
        #expect(current.count == 3)
    }

    @Test("Simulator details carry hardware, boot state, biometrics, and capabilities")
    func simulatorDetails() throws {
        let details = try #require(CoreDeviceDetails.parse(try DeviceCtlFixture.result("info-details-simulator")))
        #expect(details.device.udid == DeviceCtlFixture.simulator)
        #expect(details.device.name == "iPhone 18 Pro Max")
        #expect(details.device.isSimulated)
        #expect(details.productType == "iPhone19,3")
        #expect(details.bootState == "booted")
        #expect(details.pairingState == "paired")
        #expect(details.supportedBiometrics == ["faceID"])
        #expect(details.osBuild == "24B114")
        #expect(details.capabilities.contains { $0.featureIdentifier == "com.apple.coredevice.feature.applicationcontrol" })
    }
}

@Suite("CoreDevice real output: info")
struct CoreDeviceInfoOutputTests {
    @Test("Apps")
    func apps() throws {
        let entries = try #require(try DeviceCtlFixture.result("info-apps")["apps"]?.arrayValue)
        let apps = entries.compactMap(CoreDeviceApp.parse)
        #expect(apps.count == 2)
        let app = try #require(apps.first)
        #expect(app.bundleIdentifier == "com.amoo.companion")
        #expect(app.name == "AmooCompanion")
        #expect(app.version == "1.0")
        #expect(app.bundleVersion == "1")
        #expect(app.url?.hasSuffix("AmooCompanion.app/") == true)
        #expect(app.isRemovable)
        #expect(app.isBuiltByDeveloper)
        #expect(app.hasContainerAccess)
        #expect(app.isAppClip == false)
        #expect(app.isDefaultApp == false)
        #expect(app.raw["bundleIdentifier"]?.stringValue == "com.amoo.companion")
    }

    @Test("Processes carry a pid, and no executable on a simulator")
    func processes() throws {
        let entries = try #require(try DeviceCtlFixture.result("info-processes")["runningProcesses"]?.arrayValue)
        let processes = entries.compactMap(CoreDeviceProcess.parse)
        #expect(processes.count == 3)
        #expect(processes.first?.processIdentifier == 1)
        #expect(processes.allSatisfy { $0.executable == nil })
    }

    @Test("Displays expose the unique id capture takes, size, scale, and orientation")
    func displays() throws {
        let displays = CoreDeviceDisplays.parse(try DeviceCtlFixture.result("info-displays"))
        let primary = try #require(displays.primary)
        #expect(displays.displays.count == 1)
        #expect(primary.uniqueID == "965BC76B-3694-4358-91DA-5C23AE187A3E")
        #expect(primary.isPrimary)
        #expect(primary.name == "LCD")
        #expect(primary.nativeWidth == 1320)
        #expect(primary.nativeHeight == 2868)
        #expect(primary.pointScale == 3)
        #expect(primary.currentOrientation == "rot0")
        #expect(displays.backlightState == "activeOn")
        #expect(displays.orientation?.nonFlatOrientation == "portrait")
        #expect(displays.orientation?.isLocked == false)
    }

    @Test("Appearance")
    func appearance() throws {
        let appearance = CoreDeviceAppearance.parse(try DeviceCtlFixture.result("info-appearance"))
        #expect(appearance.userInterfaceStyle == "light")
        #expect(appearance.lookAndFeel == "Liquid Glass")
        #expect(appearance.supportedLooksAndFeels == ["Liquid Glass"])
        #expect(appearance.textSize == "Large")
        #expect(appearance.largerAccessibilitySizesEnabled == true)
        #expect(appearance.increaseContrast == false)
        #expect(appearance.reduceMotion == false)
        #expect(appearance.reduceTransparency == false)
        #expect(appearance.showBorders == false)
        #expect(appearance.liquidGlassOpacity == 0.5)
        #expect(appearance.colorFilterEnabled == false)
    }

    @Test("Audio routes follow the system default, volume is 0 to 100")
    func audio() throws {
        let audio = CoreDeviceAudioState.parse(try DeviceCtlFixture.result("info-audio"))
        #expect(audio.volume == 60)
        #expect(audio.output == .systemDefault)
        #expect(audio.input == .systemDefault)
        #expect(CoreDeviceAudioRoute.parse(.object(["device": .string("uid")])) == .other(.object(["device": .string("uid")])))
        #expect(CoreDeviceAudioRoute.parse(nil) == nil)
    }

    @Test("Orientation, biometrics, scenarios, status bar, pasteboard, icon, and host audio")
    func smallResults() throws {
        let orientation = CoreDeviceOrientationState.parse(try DeviceCtlFixture.result("orientation-get"))
        #expect(orientation.orientation == "unknown")
        #expect(orientation.nonFlatOrientation == "portrait")
        #expect(orientation.isLocked == false)

        let biometrics = CoreDeviceBiometric.parse(try DeviceCtlFixture.result("settings-biometrics-query"))
        #expect(biometrics == [CoreDeviceBiometric(type: "Face ID", isEnabled: false)])

        let scenarios = CoreDeviceLocationScenario.parse(try DeviceCtlFixture.result("simulate-location-list"))
        #expect(scenarios.map(\.name) == ["City Run", "City Bicycle Ride", "Freeway Drive", "Apple"])

        let statusBar = CoreDeviceStatusBarState.parse(try DeviceCtlFixture.result("simulate-statusbar-show"))
        #expect(statusBar.overrides.keys.sorted() == ["time"])
        #expect(statusBar.time?.hasPrefix("9:41") == true)

        let pasteboard = CoreDevicePasteboardInfo.parse(try DeviceCtlFixture.result("pasteboard-info"))
        #expect(pasteboard.pasteboardName == "general")
        #expect(pasteboard.changeCount == 162)
        #expect(pasteboard.items.count == 1)
        #expect(pasteboard.items.first?.index == 0)
        #expect(pasteboard.items.first?.types.first == "com.apple.iWork.TSPNativeData")

        let icon = CoreDeviceAppIcon.parse(try DeviceCtlFixture.result("info-appIcon"), destination: nil)
        #expect(icon.pixelWidth == 1024)
        #expect(icon.pixelHeight == 1024)
        #expect(icon.scale == 1)
        #expect(icon.isPlaceholder == false)

        let host = CoreDeviceHostAudioDevices.parse(try DeviceCtlFixture.result("list-audioDevices"))
        #expect(host.inputs.count == 3)
        #expect(host.outputs.map(\.name) == ["MacBook Pro Speakers", "MOTIV Mix Virtual"])
        #expect(host.inputs.first?.name == "Test iPhone Microphone")
        #expect(host.outputs.first?.uid == "BuiltInSpeakerDevice")
    }

    @Test("Launch reports the process, screenshot the file and size")
    func launchAndScreenshot() throws {
        let launched = try #require(CoreDeviceLaunchedProcess.parse(try DeviceCtlFixture.result("process-launch")))
        #expect(launched.processIdentifier == 63448)

        let screenshot = CoreDeviceScreenshot.parse(try DeviceCtlFixture.result("capture-screenshot"), fallbackPath: "/fallback.png")
        #expect(screenshot.path.hasSuffix("/shot.png"))
        #expect(screenshot.path.hasPrefix("file:") == false)
        #expect(screenshot.width == 1320)
        #expect(screenshot.height == 2868)
        #expect(screenshot.imageFormat == "png")
        #expect(screenshot.displayUniqueID == "965BC76B-3694-4358-91DA-5C23AE187A3E")
        #expect(CoreDeviceScreenshot.parse(.object([:]), fallbackPath: "/fallback.png").path == "/fallback.png")
    }

    @Test("VoiceOver and StandBy fields")
    func booleansAndStates() throws {
        #expect(try DeviceCtlFixture.result("info-voiceover")["enabled"]?.boolValue == false)
        #expect(try DeviceCtlFixture.result("info-standby")["state"]?.stringValue == "unavailable")
    }
}

@Suite("CoreDevice real output: failures")
struct CoreDeviceFailureOutputTests {
    @Test("An unsupported capability names the capability and the device")
    func unsupportedCapability() throws {
        let failure = try DeviceCtlFixture.failure("failure-unsupported-capability")
        #expect(failure.isUnsupportedCapability)
        #expect(failure.isDeviceNotFound == false)
        #expect(failure.code == 1001)
        #expect(failure.domain == "com.apple.dt.CoreDeviceError")
        #expect(failure.capability == "Get Lock State")
        #expect(failure.deviceIdentifier == DeviceCtlFixture.simulator)
        #expect(failure.message.contains("not supported by this device"))
        #expect(failure.command == ["devicectl", "failure-unsupported-capability"])
    }

    @Test("A missing device is code 1000")
    func deviceNotFound() throws {
        let failure = try DeviceCtlFixture.failure("failure-device-not-found")
        #expect(failure.isDeviceNotFound)
        #expect(failure.isUnsupportedCapability == false)
        #expect(failure.message.contains("specified device was not found"))
    }

    @Test("Other CoreDevice errors keep their reason")
    func reasons() throws {
        let noSession = try DeviceCtlFixture.failure("failure-no-resize-session")
        #expect(noSession.code == 24004)
        #expect(noSession.message == "Failed to query resizable app session state.")
        #expect(noSession.reason == "The specified display is not currently hosting a resizable app session.")
        #expect(noSession.capability == nil)

        let noProcess = try DeviceCtlFixture.failure("failure-no-such-process")
        #expect(noProcess.code == 10014)
        #expect(noProcess.reason == "No such process; the process may have already terminated.")
    }

    @Test("The error text carries message, reason, and code")
    func description() throws {
        let error = MobileKitError.coreDeviceFailed(try DeviceCtlFixture.failure("failure-no-resize-session"))
        #expect(
            error.errorDescription
                == "Failed to query resizable app session state. The specified display is not currently hosting a resizable app session. (com.apple.dt.CoreDeviceError 24004)"
        )
    }

    @Test("Output with no JSON is a command failure on a non-zero exit and unexpected output otherwise")
    func noJSON() {
        let failed = ShellOutput(stdout: "", stderr: "xcrun: error: unable to find utility \"devicectl\"", exitCode: 72)
        #expect(
            throws: MobileKitError.commandFailed(
                command: ["xcrun"], exitCode: 72, output: "xcrun: error: unable to find utility \"devicectl\"")
        ) {
            try DeviceCtlResponse.decode(json: "", output: failed, argv: ["xcrun"])
        }
        let silent = ShellOutput(stdout: "not json", exitCode: 0)
        #expect(throws: MobileKitError.unexpectedOutput(tool: "devicectl", detail: "no JSON result was written")) {
            try DeviceCtlResponse.decode(json: "not json", output: silent, argv: ["xcrun"])
        }
    }

    @Test("A success document carries the command type and schema version")
    func successMetadata() throws {
        let output = ShellOutput(stdout: try DeviceCtlFixture.text("info-appearance"), exitCode: 0)
        let response = try DeviceCtlResponse.decode(json: output.stdout, output: output, argv: ["devicectl"])
        #expect(response.commandType == "devicectl.device.info.appearance")
        #expect(response.jsonVersion == 5)
        #expect(response.devicectlVersion == "651.31")
    }
}
