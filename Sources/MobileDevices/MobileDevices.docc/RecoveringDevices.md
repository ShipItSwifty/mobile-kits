# Recovering hung devices

Use a manager's recovery operation when a device is offline or unresponsive. Recovery returns a
``RecoveryReport`` describing the attempted steps; the caller decides whether to retry its work or
reuse the device.

```swift
let report = try await SimulatorManager().recover(simulator.udid)
print(report.steps)
```

Simulator recovery shuts down and boots the simulator again; it does not erase it. Android device
recovery reconnects adb and may restart its server. Emulator recovery is for an emulator instance
started by the current manager and cold-boots the same AVD. These operations are mutating and may
interrupt apps or lose unsaved state, but they do not erase simulator data.

## Topics

- ``SimulatorManager/recover(_:bootTimeout:)``
- ``AndroidDeviceManager/recover(_:timeout:)``
- ``AndroidEmulatorManager/recover(_:options:timeout:)``
- ``RecoveryReport``
