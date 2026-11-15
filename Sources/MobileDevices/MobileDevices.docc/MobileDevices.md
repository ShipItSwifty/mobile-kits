# MobileDevices

Device inventory, lifecycle, recovery, capture, toolchain discovery, and cooperative device claims.

Operations are mechanisms: callers decide device selection, retries, and whether a recovered
device may be reused. See <doc:ClaimingDevices>, <doc:DeviceClaimFormat>, and
<doc:RecoveringDevices>.

## Topics

### Apple devices

- ``SimulatorManager``
- ``PhysicalIOSDeviceManager``
- ``PhysicalIOSDevice``

### Android devices

- ``AndroidDeviceManager``
- ``AndroidEmulatorManager``

### Shared device ownership

- ``DeviceClaim``
- ``DeviceClaimStore``
- ``DeviceSessionLock``
- <doc:ClaimingDevices>
- <doc:DeviceClaimFormat>

### Recovery and toolchains

- <doc:RecoveringDevices>
- ``JavaRuntimes``
- ``XcodeToolchain``
