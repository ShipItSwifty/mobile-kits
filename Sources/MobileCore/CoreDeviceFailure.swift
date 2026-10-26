/// A failure CoreDevice reported through `devicectl --json-output`, with the fields callers branch on.
///
/// The mechanism reports the facts; deciding whether an unsupported capability is fatal, skipped, or
/// retried belongs to the consumer.
public struct CoreDeviceFailure: Sendable, Equatable {
    /// The domain of every error CoreDevice itself raises.
    public static let coreDeviceDomain = "com.apple.dt.CoreDeviceError"

    /// The error code in ``domain``.
    public var code: Int
    public var domain: String
    /// The localized description.
    public var message: String
    /// The localized failure reason, when CoreDevice gave one.
    public var reason: String?
    /// The capability name for a capability error, such as `Get Lock State`.
    public var capability: String?
    /// The device the operation targeted, when CoreDevice reported it.
    public var deviceIdentifier: String?
    /// The `devicectl` argv that failed.
    public var command: [String]

    public init(
        code: Int,
        domain: String = CoreDeviceFailure.coreDeviceDomain,
        message: String,
        reason: String? = nil,
        capability: String? = nil,
        deviceIdentifier: String? = nil,
        command: [String] = []
    ) {
        self.code = code
        self.domain = domain
        self.message = message
        self.reason = reason
        self.capability = capability
        self.deviceIdentifier = deviceIdentifier
        self.command = command
    }

    /// CoreDevice found no device matching the identifier given.
    public var isDeviceNotFound: Bool { domain == Self.coreDeviceDomain && code == 1000 }

    /// The device does not support the operation, for example a simulator asked for its lock state.
    public var isUnsupportedCapability: Bool { domain == Self.coreDeviceDomain && code == 1001 }
}
