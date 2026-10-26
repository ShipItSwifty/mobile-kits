import Foundation
import MobileCore

// Typed results of `devicectl` operations. Each is decoded from the `result` object of real
// `--json-output` documents (`Tests/MobileDevicesTests/Fixtures/real/devicectl`) and ignores
// fields it does not model. Models of dynamic content keep the whole object in `raw`.

// MARK: - Device details

/// One capability a device advertises, such as `Application Control`.
public struct CoreDeviceCapability: Sendable, Equatable, Hashable {
    public var featureIdentifier: String
    public var name: String
}

/// `devicectl device info details`.
public struct CoreDeviceDetails: Sendable, Equatable {
    public var device: PhysicalIOSDevice
    public var productType: String?
    /// The OS build, such as `24B114`.
    public var osBuild: String?
    /// `booted` or `shutdown` for a simulator.
    public var bootState: String?
    /// `paired` for a device the host trusts.
    public var pairingState: String?
    /// The biometrics the hardware has, such as `faceID`.
    public var supportedBiometrics: [String]
    public var capabilities: [CoreDeviceCapability]

    static func parse(_ result: JSONValue) -> CoreDeviceDetails? {
        guard let device = PhysicalIOSDevice(json: result, includeSimulators: true) else { return nil }
        let properties = result["properties"]
        let legacy = result["deviceProperties"]
        let capabilities = (result["capabilities"]?.arrayValue ?? []).compactMap { entry -> CoreDeviceCapability? in
            guard let identifier = entry["featureIdentifier"]?.stringValue else { return nil }
            return CoreDeviceCapability(featureIdentifier: identifier, name: entry["name"]?.stringValue ?? identifier)
        }
        return CoreDeviceDetails(
            device: device,
            productType: properties?.value(at: "hardware", "productType")?.stringValue
                ?? result.value(at: "hardwareProperties", "productType")?.stringValue,
            osBuild: legacy?["osBuildUpdate"]?.stringValue
                ?? properties?.value(at: "software", "osBuildVersions")?.objectValue?.values.compactMap(\.stringValue).first,
            bootState: properties?.value(at: "state", "bootState")?.stringValue ?? legacy?["bootState"]?.stringValue,
            pairingState: properties?.value(at: "connection", "pairingState")?.stringValue
                ?? result.value(at: "connectionProperties", "pairingState")?.stringValue,
            supportedBiometrics: (properties?.value(at: "hardware", "supportedBiometrics")?.arrayValue ?? []).compactMap(\.stringValue),
            capabilities: capabilities
        )
    }
}

// MARK: - Apps and processes

/// An app from `devicectl device info apps`.
public struct CoreDeviceApp: Sendable, Equatable {
    public var bundleIdentifier: String
    public var name: String?
    /// The marketing version, `CFBundleShortVersionString`.
    public var version: String?
    /// The build number, `CFBundleVersion`.
    public var bundleVersion: String?
    /// Where the app bundle is, as a `file://` URL string.
    public var url: String?
    public var isRemovable: Bool
    public var isAppClip: Bool
    public var isDefaultApp: Bool
    public var isHidden: Bool
    public var isInternal: Bool
    public var isBuiltByDeveloper: Bool
    /// Whether devicectl can reach the app's data container, which `device copy` needs.
    public var hasContainerAccess: Bool
    /// The whole entry, including app group identifiers and container paths when requested.
    public var raw: JSONValue

    static func parse(_ entry: JSONValue) -> CoreDeviceApp? {
        guard let bundleIdentifier = entry["bundleIdentifier"]?.stringValue else { return nil }
        return CoreDeviceApp(
            bundleIdentifier: bundleIdentifier,
            name: entry["name"]?.stringValue,
            version: entry["version"]?.stringValue,
            bundleVersion: entry["bundleVersion"]?.stringValue,
            url: entry["url"]?.stringValue,
            isRemovable: entry["removable"]?.boolValue ?? false,
            isAppClip: entry["appClip"]?.boolValue ?? false,
            isDefaultApp: entry["defaultApp"]?.boolValue ?? false,
            isHidden: entry["hidden"]?.boolValue ?? false,
            isInternal: entry["internalApp"]?.boolValue ?? false,
            isBuiltByDeveloper: entry["builtByDeveloper"]?.boolValue ?? false,
            hasContainerAccess: entry["containerAccessible"]?.boolValue ?? false,
            raw: entry
        )
    }
}

/// A process from `devicectl device info processes`.
public struct CoreDeviceProcess: Sendable, Equatable {
    public var processIdentifier: Int32
    /// The executable's `file://` URL string; a simulator does not report one.
    public var executable: String?
    public var raw: JSONValue

    static func parse(_ entry: JSONValue) -> CoreDeviceProcess? {
        guard let pid = entry["processIdentifier"]?.wholeNumberValue, let identifier = Int32(exactly: pid) else { return nil }
        return CoreDeviceProcess(processIdentifier: identifier, executable: entry["executable"]?.stringValue, raw: entry)
    }
}

/// The process `devicectl device process launch` started.
public struct CoreDeviceLaunchedProcess: Sendable, Equatable {
    public var processIdentifier: Int32

    static func parse(_ result: JSONValue) -> CoreDeviceLaunchedProcess? {
        guard let pid = result.value(at: "process", "processIdentifier")?.wholeNumberValue, let identifier = Int32(exactly: pid) else {
            return nil
        }
        return CoreDeviceLaunchedProcess(processIdentifier: identifier)
    }
}

// MARK: - Display and orientation

/// How a device is oriented, from `device orientation get` or the orientation block of `device info displays`.
public struct CoreDeviceOrientationState: Sendable, Equatable {
    /// The raw orientation, which is `unknown` for a device lying flat or a simulator.
    public var orientation: String?
    /// The last orientation that was not face up or face down.
    public var nonFlatOrientation: String?
    public var isLocked: Bool?

    static func parse(_ result: JSONValue) -> CoreDeviceOrientationState {
        CoreDeviceOrientationState(
            orientation: result["deviceOrientation"]?.stringValue ?? result["currentDeviceOrientation"]?.stringValue,
            nonFlatOrientation: result["deviceOrientationNonFlat"]?.stringValue ?? result["currentDeviceNonFlatOrientation"]?.stringValue,
            isLocked: result["deviceIsOrientationLocked"]?.boolValue ?? result["currentDeviceOrientationLocked"]?.boolValue
        )
    }
}

/// A display from `devicectl device info displays`.
public struct CoreDeviceDisplay: Sendable, Equatable {
    /// The id `--display-unique-id` and `--display` take.
    public var uniqueID: String
    public var displayID: Int?
    public var name: String?
    public var isPrimary: Bool
    /// The native resolution in pixels.
    public var nativeWidth: Double?
    public var nativeHeight: Double?
    public var pointScale: Double?
    /// `rot0`, `rot90`, ….
    public var currentOrientation: String?
    public var backlightState: String?
    public var raw: JSONValue

    static func parse(_ entry: JSONValue) -> CoreDeviceDisplay? {
        guard let uniqueID = entry["uniqueId"]?.stringValue else { return nil }
        let size = entry["nativeSize"]?.arrayValue ?? []
        return CoreDeviceDisplay(
            uniqueID: uniqueID,
            displayID: entry["displayId"]?.wholeNumberValue,
            name: entry["name"]?.stringValue,
            isPrimary: entry["primary"]?.boolValue ?? false,
            nativeWidth: size.first?.numberValue,
            nativeHeight: size.dropFirst().first?.numberValue,
            pointScale: entry["pointScale"]?.numberValue,
            currentOrientation: entry["currentOrientation"]?.stringValue,
            backlightState: entry["backlightState"]?.stringValue,
            raw: entry
        )
    }
}

/// `devicectl device info displays`.
public struct CoreDeviceDisplays: Sendable, Equatable {
    public var displays: [CoreDeviceDisplay]
    public var backlightState: String?
    public var orientation: CoreDeviceOrientationState?

    /// The primary display, or the first when none is marked primary.
    public var primary: CoreDeviceDisplay? { displays.first(where: \.isPrimary) ?? displays.first }

    static func parse(_ result: JSONValue) -> CoreDeviceDisplays {
        CoreDeviceDisplays(
            displays: (result["displays"]?.arrayValue ?? []).compactMap(CoreDeviceDisplay.parse),
            backlightState: result["backlightState"]?.stringValue,
            orientation: result["orientation"].map(CoreDeviceOrientationState.parse)
        )
    }
}

// MARK: - Settings state

/// `devicectl device info appearance`.
public struct CoreDeviceAppearance: Sendable, Equatable {
    /// `light` or `dark`.
    public var userInterfaceStyle: String?
    public var lookAndFeel: String?
    public var supportedLooksAndFeels: [String]
    /// The text size as devicectl reports it, such as `Large`.
    public var textSize: String?
    public var largerAccessibilitySizesEnabled: Bool?
    public var increaseContrast: Bool?
    public var reduceMotion: Bool?
    public var reduceTransparency: Bool?
    public var showBorders: Bool?
    public var liquidGlassOpacity: Double?
    public var colorFilterEnabled: Bool?

    static func parse(_ result: JSONValue) -> CoreDeviceAppearance {
        CoreDeviceAppearance(
            userInterfaceStyle: result["userInterfaceStyle"]?.stringValue,
            lookAndFeel: result["lookAndFeel"]?.stringValue,
            supportedLooksAndFeels: (result["supportedLooksAndFeels"]?.arrayValue ?? []).compactMap(\.stringValue),
            textSize: result["textSize"]?.stringValue,
            largerAccessibilitySizesEnabled: result["largerAccessibilitySizesEnabled"]?.boolValue,
            increaseContrast: result["increaseContrast"]?.boolValue,
            reduceMotion: result.value(at: "reduceMotion", "enabled")?.boolValue,
            reduceTransparency: result.value(at: "reduceTransparency", "enabled")?.boolValue,
            showBorders: result.value(at: "showBorders", "enabled")?.boolValue,
            liquidGlassOpacity: result["liquidGlassOpacity"]?.numberValue,
            colorFilterEnabled: result.value(at: "colorFilter", "enabled")?.boolValue
        )
    }
}

/// An audio input or output route on a device.
public enum CoreDeviceAudioRoute: Sendable, Equatable {
    /// Follows the host's default audio device.
    case systemDefault
    /// Anything else devicectl reports, kept as it came.
    case other(JSONValue)

    static func parse(_ value: JSONValue?) -> CoreDeviceAudioRoute? {
        guard let value else { return nil }
        return value["systemDefault"] != nil ? .systemDefault : .other(value)
    }
}

/// `devicectl device info audio`.
public struct CoreDeviceAudioState: Sendable, Equatable {
    /// 0 to 100.
    public var volume: Int?
    public var output: CoreDeviceAudioRoute?
    public var input: CoreDeviceAudioRoute?

    static func parse(_ result: JSONValue) -> CoreDeviceAudioState {
        CoreDeviceAudioState(
            volume: result["volume"]?.wholeNumberValue,
            output: CoreDeviceAudioRoute.parse(result["audioOutputDevice"]),
            input: CoreDeviceAudioRoute.parse(result["audioInputDevice"])
        )
    }
}

/// A biometric type and whether it is enrolled, from `devicectl device settings biometrics`.
public struct CoreDeviceBiometric: Sendable, Equatable, Hashable {
    /// `Face ID`, `Touch ID`, or `Optic ID`.
    public var type: String
    public var isEnabled: Bool

    static func parse(_ result: JSONValue) -> [CoreDeviceBiometric] {
        (result["biometrics"]?.arrayValue ?? []).compactMap { entry in
            guard let type = entry["type"]?.stringValue else { return nil }
            return CoreDeviceBiometric(type: type, isEnabled: entry["enabled"]?.boolValue ?? false)
        }
    }
}

/// A named location route from `devicectl device simulate location list`.
public struct CoreDeviceLocationScenario: Sendable, Equatable, Hashable {
    /// The value `simulateLocationScenario` takes.
    public var name: String
    public var localizedName: String

    static func parse(_ result: JSONValue) -> [CoreDeviceLocationScenario] {
        (result["availableScenarios"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            return CoreDeviceLocationScenario(name: name, localizedName: entry["localizedName"]?.stringValue ?? name)
        }
    }
}

/// The status bar overrides currently applied, from `devicectl device simulate statusBar show`.
///
/// devicectl reports only some of the overrides it accepts: after setting a time and a battery
/// level, `show` has the time alone. Read this as what devicectl chose to echo, not as the full state.
public struct CoreDeviceStatusBarState: Sendable, Equatable {
    /// Every override devicectl reported; empty when none is in force.
    public var overrides: [String: JSONValue]

    /// The time shown, with devicectl's narrow no-break space before `AM`/`PM` left as it came.
    public var time: String? { overrides["time"]?.stringValue }

    static func parse(_ result: JSONValue) -> CoreDeviceStatusBarState {
        var values = result.objectValue ?? [:]
        values["deviceIdentifier"] = nil
        return CoreDeviceStatusBarState(overrides: values)
    }
}

// MARK: - Pasteboard

/// One item on a pasteboard and the types it offers.
public struct CoreDevicePasteboardItem: Sendable, Equatable {
    public var index: Int
    /// The UTIs of the item's flavors.
    public var types: [String]
}

/// `devicectl device pasteboard info`. No pasteboard data crosses to the host.
public struct CoreDevicePasteboardInfo: Sendable, Equatable {
    public var pasteboardName: String?
    /// Increases each time the pasteboard changes.
    public var changeCount: Int?
    public var items: [CoreDevicePasteboardItem]

    static func parse(_ result: JSONValue) -> CoreDevicePasteboardInfo {
        let items = (result["items"]?.arrayValue ?? []).enumerated().map { offset, item in
            CoreDevicePasteboardItem(
                index: item["index"]?.wholeNumberValue ?? offset,
                types: (item["flavors"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue }
            )
        }
        return CoreDevicePasteboardInfo(
            pasteboardName: result["pasteboardName"]?.stringValue,
            changeCount: result["changeCount"]?.wholeNumberValue,
            items: items
        )
    }
}

// MARK: - Capture

/// A rendered app icon from `devicectl device info appIcon`.
public struct CoreDeviceAppIcon: Sendable, Equatable {
    public var pixelWidth: Double?
    public var pixelHeight: Double?
    public var scale: Double?
    public var isPlaceholder: Bool
    /// The PNG on the host, when a destination was requested.
    public var destination: String?

    static func parse(_ result: JSONValue, destination: String?) -> CoreDeviceAppIcon {
        CoreDeviceAppIcon(
            pixelWidth: result.value(at: "icon", "pixelSize", "width")?.numberValue,
            pixelHeight: result.value(at: "icon", "pixelSize", "height")?.numberValue,
            scale: result.value(at: "icon", "scale")?.numberValue,
            isPlaceholder: result.value(at: "icon", "placeholder")?.boolValue ?? false,
            destination: destination
        )
    }
}

/// A screenshot `devicectl device capture screenshot` wrote.
public struct CoreDeviceScreenshot: Sendable, Equatable {
    /// The host path, as a plain file path.
    public var path: String
    public var width: Int?
    public var height: Int?
    public var imageFormat: String?
    public var displayUniqueID: String?

    static func parse(_ result: JSONValue, fallbackPath: String) -> CoreDeviceScreenshot {
        let destination = result["destination"]?.stringValue
        let path = destination.flatMap { URL(string: $0)?.path } ?? fallbackPath
        return CoreDeviceScreenshot(
            path: path,
            width: result["width"]?.wholeNumberValue,
            height: result["height"]?.wholeNumberValue,
            imageFormat: result["imageFormat"]?.stringValue,
            displayUniqueID: result["displayUniqueID"]?.stringValue
        )
    }
}

// MARK: - Host

/// An audio device on the host, from `devicectl list audioDevices`.
public struct CoreDeviceHostAudioDevice: Sendable, Equatable, Hashable {
    public var name: String
    /// The id `devicectl device settings audio` takes.
    public var uid: String
}

/// The host's audio devices.
public struct CoreDeviceHostAudioDevices: Sendable, Equatable {
    public var inputs: [CoreDeviceHostAudioDevice]
    public var outputs: [CoreDeviceHostAudioDevice]

    static func parse(_ result: JSONValue) -> CoreDeviceHostAudioDevices {
        func devices(_ key: String) -> [CoreDeviceHostAudioDevice] {
            (result[key]?.arrayValue ?? []).compactMap { entry in
                guard let name = entry["name"]?.stringValue, let uid = entry["uid"]?.stringValue else { return nil }
                return CoreDeviceHostAudioDevice(name: name, uid: uid)
            }
        }
        return CoreDeviceHostAudioDevices(inputs: devices("inputDevices"), outputs: devices("outputDevices"))
    }
}
