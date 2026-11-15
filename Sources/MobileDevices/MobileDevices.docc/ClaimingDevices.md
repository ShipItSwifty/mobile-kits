# Claiming devices

Use ``DeviceClaimStore`` when multiple processes may drive the same simulator, emulator, or
physical device. The store uses a per-device lock so concurrent acquisitions cannot both succeed.

```swift
let claims = DeviceClaimStore(directory: DeviceClaimStore.sharedDirectory())
let claim = try claims.acquire(platform: .android, deviceID: serial, owner: "test-run")
defer { claims.release(claim) }
```

Use the same directory in every cooperating process. `sharedDirectory()` honors
`AMOO_LEASE_DIR`; otherwise it returns `~/.amoo/leases`. Claims expire after the configured TTL.
Call ``DeviceClaimStore/renew(_:now:)`` for long-running work. A reader never removes an expired
claim; acquisition or an explicit reap performs cleanup while holding the device lock.

The claim is cooperative: callers must check access before operating on a device and release or
renew the claim as appropriate. For the shared JSON and lock-file contract, see
<doc:DeviceClaimFormat>.

## Topics

- ``DeviceClaimStore``
- ``DeviceSessionLock``
- ``ClaimAccess``
- <doc:DeviceClaimFormat>
