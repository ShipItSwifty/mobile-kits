# Real tool output

Artifacts captured from real runs, replayed by `CoreDeviceRealOutputTests`. They exist so the `devicectl`
models are checked against what the tool actually writes, not against hand-written approximations.

All were captured with `--json-output` from devicectl 651.31 (Xcode 27.2, jsonVersion 5) against an iOS 27.2
simulator. Command arguments, environment, and home paths are scrubbed, UDIDs of the simulator are replaced with
`11111111-2222-3333-4444-555555555555`, and long lists are trimmed.

| Path | Captured from |
|---|---|
| `devicectl/list-devices.json` | `devicectl list devices`: a booted and a shutdown simulator (`reality: simulated`) and one physical iPhone whose name, UDID, ECID, serial number, and hostnames are replaced. Carries both the new `properties` dictionary and the deprecated `hardwareProperties`, `deviceProperties`, `connectionProperties` keys. |
| `devicectl/list-devices-omit-deprecated.json` | The same list with the deprecated keys removed, as `--omit-deprecated-fields-in-json` writes it. |
| `devicectl/info-*.json`, `orientation-get.json`, `pasteboard-info.json`, `settings-biometrics-query.json`, `simulate-*.json`, `list-audioDevices.json` | The matching `devicectl device …` / `devicectl list …` command. The apps list keeps two entries, processes three, pasteboard flavors three; a host microphone name is replaced. |
| `devicectl/process-launch.json`, `capture-screenshot.json` | `device process launch --terminate-existing` of Settings and `device capture screenshot`. |
| `devicectl/failure-*.json` | Failed runs, which still write JSON: a capability the simulator lacks (`info lockState`, code 1001), a device that does not exist (code 1000), no resizable session (code 24004), and signalling a process that already exited (code 10014). |

Not captured: results a simulator does not support (`info files`, `info lockState`, `profile list`, Darwin notifications)
or that change the device irreversibly (`install`, `reboot`, `rename`, `settings reset`). Those operations return
the raw `DeviceCtlResponse` until a real document from a capable device is added here.

To refresh one, re-run the command and replace the file; the tests state what they expect.
