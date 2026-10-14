import Foundation

/// A mobile operating system a device runs or an app targets.
public enum MobilePlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case ios
    case android

    /// Decodes `"iOS"`, `"IOS"`, `"Android"`, … as well as the canonical lowercase values.
    public init?(lenient value: String) {
        self.init(rawValue: value.lowercased())
    }
}

/// Whether a device is virtual (and so can be created, booted, erased) or real hardware.
public enum DeviceKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// An iOS Simulator.
    case simulator
    /// An Android Virtual Device running in the emulator.
    case emulator
    /// Real hardware attached over USB or the network.
    case physical
}

/// Identifies one device: an iOS Simulator or device UDID, or an adb serial.
public struct DeviceIdentity: Codable, Sendable, Hashable, CustomStringConvertible {
    public var platform: MobilePlatform
    public var id: String

    public init(platform: MobilePlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    public var description: String { "\(platform.rawValue):\(id)" }
}
