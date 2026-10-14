import Foundation
import MobileCore
import Synchronization
import TestCommons
import Testing

@testable import MobileDevices

@Suite("DeviceClaimStore")
struct DeviceClaimStoreTests {
    final class Reaped: Sendable {
        private let ids = Mutex<[String]>([])
        func record(_ id: String) { ids.withLock { $0.append(id) } }
        var all: [String] { ids.withLock { $0 } }
    }

    func store(_ scratch: TemporaryDirectory, ttl: TimeInterval = 60, reaped: Reaped? = nil) -> DeviceClaimStore {
        DeviceClaimStore(directory: scratch.url.appending(path: "leases"), ttl: ttl) { reaped?.record($0.id) }
    }

    @Test("Acquire is exclusive and the holder owns access")
    func exclusive() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = store(scratch)
        let claim = try store.acquire(platform: .android, deviceID: "emulator-5554", owner: "a")
        #expect(throws: MobileKitError.self) { try store.acquire(platform: .android, deviceID: "emulator-5554") }
        #expect(store.access(deviceID: "emulator-5554", presenting: claim.id) == .owned(claim))
        #expect(store.access(deviceID: "emulator-5554", presenting: nil) == .claimedByOther(claim))
        #expect(store.access(deviceID: "emulator-5556", presenting: nil) == .free)
    }

    @Test("Claim files are private and complete from the moment they appear")
    func privatePublication() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = store(scratch)
        let claim = try store.acquire(platform: .ios, deviceID: "U")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL(deviceID: "U").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(store.claim(forDevice: "U") == claim)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("Reading an expired claim neither reaps nor removes it")
    func readsAreSideEffectFree() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let reaped = Reaped()
        let store = store(scratch, reaped: reaped)
        let claim = try store.acquire(platform: .android, deviceID: "S", now: Date().addingTimeInterval(-3600))
        #expect(store.all().isEmpty)
        #expect(store.claim(forDevice: "S") == nil)
        #expect(store.claim(id: claim.id) == nil)
        #expect(store.access(deviceID: "S", presenting: nil) == .free)
        #expect(store.allIncludingExpired().map(\.id) == [claim.id])
        #expect(reaped.all.isEmpty)
    }

    @Test("Acquiring a device reaps its expired claim first")
    func acquireReaps() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let reaped = Reaped()
        let store = store(scratch, reaped: reaped)
        let expired = try store.acquire(platform: .android, deviceID: "S", now: Date().addingTimeInterval(-3600))
        let fresh = try store.acquire(platform: .android, deviceID: "S")
        #expect(reaped.all == [expired.id])
        #expect(store.claim(forDevice: "S") == fresh)
    }

    @Test("Sweeping skips a device another session is driving")
    func sweepSkipsLocked() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let reaped = Reaped()
        let store = store(scratch, reaped: reaped)
        _ = try store.acquire(platform: .android, deviceID: "S", now: Date().addingTimeInterval(-3600))
        let lock = try DeviceSessionLock(deviceID: "S", store: store)
        #expect(store.reapExpired().isEmpty)
        lock.release()
        #expect(store.reapExpired().count == 1)
        #expect(store.reapExpired().isEmpty, "already removed, so reaped once")
        #expect(reaped.all.count == 1)
    }

    @Test("Renew refuses a claim someone else now holds; release works after expiry")
    func renewAndRelease() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = store(scratch)
        let claim = try store.acquire(platform: .ios, deviceID: "U", now: Date().addingTimeInterval(-3600))
        var impostor = claim
        impostor.id = "lease-other"
        #expect(throws: MobileKitError.self) { try store.renew(impostor) }
        store.release(impostor)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(deviceID: "U").path))
        store.release(claim)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(deviceID: "U").path))
    }

    @Test("Reads claims written by existing tools in the shared on-disk format")
    func interoperability() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = store(scratch)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let json = """
            {
              "appID" : "com.jot",
              "bootedByLease" : true,
              "createdAt" : "2099-01-01T00:00:00.123Z",
              "deviceID" : "A1B2",
              "expiresAt" : "2099-01-01T01:00:00Z",
              "holderPID" : 4242,
              "id" : "lease-abcd1234",
              "owner" : "shipit pid 1",
              "platform" : "ios",
              "port" : 22087
            }
            """
        try Data(json.utf8).write(to: store.fileURL(deviceID: "A1B2"))
        let claim = try #require(store.claim(forDevice: "A1B2"))
        #expect(claim.id == "lease-abcd1234")
        #expect(claim.port == 22087)
        #expect(claim.holderPID == 4242)
        #expect(claim.platform == .ios)
        let encoded = try #require(String(bytes: DeviceClaimStore.encoder.encode(claim), encoding: .utf8))
        #expect(encoded.contains(#""createdAt" : "2099-01-01T00:00:00.123Z""#))
    }

    @Test("A second session lock on the same device is refused until released")
    func sessionLock() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = store(scratch)
        let first = try DeviceSessionLock(deviceID: "U", store: store)
        #expect(throws: MobileKitError.self) { try DeviceSessionLock(deviceID: "U", store: store) }
        first.release()
        let second = try DeviceSessionLock(deviceID: "U", store: store)
        second.release()
    }
}
