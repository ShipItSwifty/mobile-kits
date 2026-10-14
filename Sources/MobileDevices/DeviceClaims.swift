import Foundation
import Logging
import MobileCore
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A cooperative claim on one device, so concurrent tools and sessions stop driving each other's
/// simulators and emulators.
///
/// This is an on-disk interchange format shared by every tool that coordinates through the
/// same directory: field names, the lowercase platform, and ISO-8601 dates with fractional
/// seconds must stay stable.
public struct DeviceClaim: Codable, Equatable, Sendable {
    public var id: String
    public var platform: MobilePlatform
    /// Simulator UDID or adb serial.
    public var deviceID: String
    public var deviceName: String?
    /// A port the holder serves on for this device, if any.
    public var port: Int?
    /// A long-lived process holding resources for this claim (e.g. a companion server).
    public var holderPID: Int32?
    /// Whether the claim's holder booted the device, so it may shut it down on release.
    public var bootedByLease: Bool
    public var appID: String?
    /// Free-form caller label shown to anyone refused.
    public var owner: String?
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: String,
        platform: MobilePlatform,
        deviceID: String,
        deviceName: String? = nil,
        port: Int? = nil,
        holderPID: Int32? = nil,
        bootedByLease: Bool = false,
        appID: String? = nil,
        owner: String? = nil,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.platform = platform
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.port = port
        self.holderPID = holderPID
        self.bootedByLease = bootedByLease
        self.appID = appID
        self.owner = owner
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

/// What a caller presenting a claim id may do with a device.
public enum ClaimAccess: Equatable, Sendable {
    case free
    case owned(DeviceClaim)
    case claimedByOther(DeviceClaim)
}

/// One JSON file per device in a shared directory.
///
/// Reads never modify anything: an expired claim reads as free but stays on disk until a caller
/// that is taking the device (``acquire(platform:deviceID:deviceName:owner:holderPID:now:)``,
/// ``reapExpired(now:)``) retires it under the device's ``DeviceSessionLock``, after running the
/// consumer's `reaper` for whatever the old holder left running.
public struct DeviceClaimStore: Sendable {
    public static let defaultTTL: TimeInterval = 60 * 60

    public let directory: URL
    public let ttl: TimeInterval
    /// Stops what an expired claim's holder left running, before the claim file is removed.
    /// Only the consumer knows what that is; the default does nothing.
    public let reaper: @Sendable (DeviceClaim) -> Void
    private let logger = Logger.forType(DeviceClaimStore.self)

    public init(
        directory: URL,
        ttl: TimeInterval = Self.defaultTTL,
        reaper: @escaping @Sendable (DeviceClaim) -> Void = { _ in }
    ) {
        self.directory = directory
        self.ttl = ttl
        self.reaper = reaper
    }

    /// `$AMOO_LEASE_DIR`, else `~/.amoo/leases`: the directory existing tools already coordinate through.
    public static func sharedDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AMOO_LEASE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".amoo/leases", isDirectory: true)
    }

    // MARK: - Reads (side-effect free)

    /// Active (unexpired) claims, oldest first.
    public func all(now: Date = Date()) -> [DeviceClaim] {
        stored().filter { !$0.isExpired(at: now) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Every readable claim, including expired ones, for diagnostics.
    public func allIncludingExpired() -> [DeviceClaim] {
        stored().sorted { $0.createdAt < $1.createdAt }
    }

    public func claim(forDevice deviceID: String, now: Date = Date()) -> DeviceClaim? {
        read(fileURL(deviceID: deviceID)).flatMap { $0.isExpired(at: now) ? nil : $0 }
    }

    public func claim(id: String, now: Date = Date()) -> DeviceClaim? {
        all(now: now).first { $0.id == id }
    }

    public func access(deviceID: String, presenting claimID: String?, now: Date = Date()) -> ClaimAccess {
        guard let claim = claim(forDevice: deviceID, now: now) else { return .free }
        return claim.id == claimID ? .owned(claim) : .claimedByOther(claim)
    }

    // MARK: - Writes

    /// Claims a device. Two processes racing for it cannot both win: the claim file is published
    /// with an exclusive hard link, so readers only ever see a complete record.
    ///
    /// - Throws: ``MobileKitError/deviceClaimed(device:holder:)`` when someone else holds it.
    public func acquire(
        platform: MobilePlatform,
        deviceID: String,
        deviceName: String? = nil,
        owner: String? = nil,
        holderPID: Int32? = nil,
        now: Date = Date()
    ) throws -> DeviceClaim {
        let lock = try DeviceSessionLock(deviceID: deviceID, store: self)
        defer { lock.release() }
        reapIfExpired(deviceID: deviceID, now: now)
        if let existing = claim(forDevice: deviceID, now: now) {
            throw MobileKitError.deviceClaimed(device: deviceID, holder: Self.holderDescription(existing))
        }
        let created = Self.storedPrecision(now)
        let claim = DeviceClaim(
            id: "lease-" + UUID().uuidString.prefix(8).lowercased(),
            platform: platform, deviceID: deviceID, deviceName: deviceName, holderPID: holderPID, owner: owner,
            createdAt: created, expiresAt: Self.storedPrecision(now.addingTimeInterval(ttl))
        )
        try publish(claim)
        logger.info("Claimed device", metadata: ["device": "\(deviceID)", "claim": "\(claim.id)"])
        return claim
    }

    /// Persists changes to an owned claim and pushes its expiry out by one TTL. Refuses to
    /// overwrite a claim someone else now holds.
    @discardableResult
    public func renew(_ claim: DeviceClaim, now: Date = Date()) throws -> DeviceClaim {
        guard read(fileURL(deviceID: claim.deviceID))?.id == claim.id else {
            throw MobileKitError.notFound("Claim \(claim.id) on \(claim.deviceID) no longer exists")
        }
        var renewed = claim
        renewed.expiresAt = Self.storedPrecision(now.addingTimeInterval(ttl))
        try replace(renewed)
        return renewed
    }

    /// Removes the claim if it is still this one. Works after expiry, so an owner can clean up late.
    public func release(_ claim: DeviceClaim) {
        guard read(fileURL(deviceID: claim.deviceID))?.id == claim.id else { return }
        try? FileManager.default.removeItem(at: fileURL(deviceID: claim.deviceID))
        logger.info("Released device", metadata: ["device": "\(claim.deviceID)", "claim": "\(claim.id)"])
    }

    /// Retires every expired claim whose device no session is driving. Each device is re-read
    /// under its ``DeviceSessionLock``, so a claim taken meanwhile is never removed.
    @discardableResult
    public func reapExpired(now: Date = Date()) -> [DeviceClaim] {
        stored().filter { $0.isExpired(at: now) }.compactMap { expired in
            guard let lock = try? DeviceSessionLock(deviceID: expired.deviceID, store: self) else { return nil }
            defer { lock.release() }
            return reapIfExpired(deviceID: expired.deviceID, now: now)
        }
    }

    /// Runs the reaper for the device's expired claim and removes it. The caller must hold the
    /// device's ``DeviceSessionLock``.
    @discardableResult
    public func reapIfExpired(deviceID: String, now: Date = Date()) -> DeviceClaim? {
        let url = fileURL(deviceID: deviceID)
        guard let claim = read(url), claim.isExpired(at: now) else { return nil }
        logger.info("Reaping expired claim", metadata: ["device": "\(deviceID)", "claim": "\(claim.id)"])
        reaper(claim)
        try? FileManager.default.removeItem(at: url)
        return claim
    }

    /// Log file for a claim's long-lived holder process.
    public func logURL(claimID: String) -> URL {
        directory.appendingPathComponent("\(claimID).log")
    }

    // MARK: - Files

    /// `<directory>/<sanitized device id>.json`. The sanitizing keeps letters, digits, `-` and `.`;
    /// it must not change, or tools stop finding each other's claims.
    public func fileURL(deviceID: String) -> URL {
        let safe = deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// Dates are stored with millisecond precision; truncating up front makes a returned claim
    /// equal to the one read back from disk.
    static func storedPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    static func holderDescription(_ claim: DeviceClaim) -> String {
        "\(claim.id)\(claim.owner.map { " (\($0))" } ?? ""), expires \(ISO8601DateFormatter().string(from: claim.expiresAt))"
    }

    private func stored() -> [DeviceClaim] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap(read)
    }

    private func read(_ url: URL) -> DeviceClaim? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? Self.decoder.decode(DeviceClaim.self, from: data)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes to a private temporary file, then hard-links it into place: `link` fails if the
    /// claim file exists, so publication is exclusive and atomic.
    private func publish(_ claim: DeviceClaim) throws {
        try ensureDirectory()
        let temporary = try writeTemporary(claim)
        defer { unlink(temporary.path) }
        guard link(temporary.path, fileURL(deviceID: claim.deviceID).path) == 0 else {
            let code = errno
            if code == EEXIST, let winner = read(fileURL(deviceID: claim.deviceID)) {
                throw MobileKitError.deviceClaimed(device: claim.deviceID, holder: Self.holderDescription(winner))
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Atomically replaces an existing claim file.
    private func replace(_ claim: DeviceClaim) throws {
        try ensureDirectory()
        let temporary = try writeTemporary(claim)
        guard rename(temporary.path, fileURL(deviceID: claim.deviceID).path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func writeTemporary(_ claim: DeviceClaim) throws -> URL {
        let url = directory.appendingPathComponent(".\(claim.id).\(UUID().uuidString).tmp")
        let data = try Self.encoder.encode(claim)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw POSIXError(.EIO)
        }
        return url
    }

    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter().date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
            }
            return date
        }
        return decoder
    }()
}

/// Kernel-backed exclusive ownership of a device for the life of a session, shared by every
/// process. The kernel releases it if the holder crashes; the lock file is never unlinked while
/// another process may be opening it.
///
/// `flock` locks belong to an open file description: a second lock on the same device from the
/// same process fails like one from another process.
public final class DeviceSessionLock: Sendable {
    private let descriptor: Mutex<Int32>
    public let deviceID: String

    /// - Throws: ``MobileKitError/deviceClaimed(device:holder:)`` when another session holds it.
    public init(deviceID: String, store: DeviceClaimStore) throws {
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = store.fileURL(deviceID: deviceID).appendingPathExtension("session-lock").path
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            throw MobileKitError.deviceClaimed(device: deviceID, holder: "another active session")
        }
        self.deviceID = deviceID
        self.descriptor = Mutex(file)
    }

    public func release() {
        descriptor.withLock { file in
            if file >= 0 {
                _ = flock(file, LOCK_UN)
                close(file)
                file = -1
            }
        }
    }

    deinit { release() }
}
