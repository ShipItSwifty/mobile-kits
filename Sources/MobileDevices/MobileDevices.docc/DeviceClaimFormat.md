# Device claim file format

`DeviceClaimStore` is an interchange format shared by tools. Keep these names and encodings stable
unless all consumers coordinate a versioned migration.

## Claim document

There is one JSON document per device at `<directory>/<sanitized-device-id>.json`. The device ID
keeps letters, digits, `-`, and `.`; every other character becomes `_`. JSON keys are sorted and
the document is pretty-printed. The fields are:

| Key | Meaning |
| --- | --- |
| `id` | Claim identifier |
| `platform` | Lowercase `MobilePlatform` value |
| `deviceID` | Simulator UDID or device serial |
| `deviceName` | Optional display name |
| `port` | Optional forwarded port |
| `holderPID` | Optional long-lived holder process ID |
| `bootedByLease` | Whether the holder booted the device |
| `appID` | Optional installed app identifier |
| `owner` | Optional caller label |
| `createdAt`, `expiresAt` | ISO 8601 UTC dates with fractional seconds, stored at millisecond precision |

Optional values are omitted when absent. Writers create a private temporary file and publish it by
an exclusive hard link, so a reader does not observe a partially written claim. The claim
directory is created with owner-only permissions; claim files use mode `0600`.

## Lock files

The lock for a device is `<sanitized-device-id>.json.session-lock` beside its claim. It is
kernel-locked for the session and is intentionally not unlinked: removing a lock file while another
process may have it open could allow two processes to lock different inodes for the same device.
Temporary claim files use `.<claim-id>.<uuid>.tmp` and are removed after publication.

## Topics

- ``DeviceClaim``
- ``DeviceClaimStore``
- ``DeviceSessionLock``
