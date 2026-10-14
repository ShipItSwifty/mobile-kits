# mobile-kits — agent guidance

Mobile build, device, and test mechanisms shared by [ShipItSwifty](https://github.com/ShipItSwifty/shipitswifty)
(release automation) and Amoo (device automation for AI agents), built on the typed tool wrappers in
[`ShipItSwifty/cli-wrappers`](https://github.com/ShipItSwifty/cli-wrappers).

## What belongs here

Mechanisms both tools need: building and archiving apps, device inventory and lifecycle (boot,
relaunch, reset, recover a hung simulator or emulator), device claims, running tests, and reading
native results into one model.

Not here: **policies** (test retries, flaky classification across attempts, coverage gates, failure
audits, telemetry, reporting, store submission) stay in ShipIt; **orchestration** (companions, MCP,
recording, code generation) stays in Amoo. A mechanism takes explicit inputs and returns facts and
outcomes; it never decides exit codes, prompts, or user-facing remediation.

## Products

| Product | Holds |
| --- | --- |
| `MobileCore` | Platforms, frameworks, backends, `MobileKitError`, `ToolRunner`, `Poller`, `JSONValue` |
| `MobileDevices` | Simulators, Android devices and emulators, physical iOS devices, `DeviceClaimStore`, JDK/Xcode discovery |
| `MobileBuild` | Xcode, Gradle, Flutter, React Native, KMP, SwiftPM, Bazel builders; project generation; signing inspection |
| `MobileTesting` | Native result model and parsers; Xcode, Gradle, SwiftPM, Flutter, Jest, Bazel test runners |
| `MobileProject` | Read-only repository inspection; SwiftSyntax UI-test harness discovery |

SwiftSyntax is a dependency of `MobileProject` only.

## Commands

```bash
swift build
swift test
swift format lint --recursive --strict --configuration .swift-format Sources Tests Package.swift
swift format --in-place --recursive --configuration .swift-format Sources Tests Package.swift
```

Run the format lint after the final edit. Linux CI builds and tests everything; Apple-only
operations throw `MobileKitError.unsupportedHost` there instead of being compiled out.

## Conventions

- Swift tools 6.2, Swift 6 language mode, `Sendable` public types, Swift Testing.
- Logging through swift-log (`Logger.forType`), before and after every external command and on every
  error, with identifiers rather than user data.
- Products come from what tools report (`-showBuildSettings -json`, `output-metadata.json`, the Bazel
  build event stream, Flutter's `✓ Built` lines), never from guessing conventional paths.
- `DeviceClaimStore`'s files are an interchange format other tools read: keep field names and dates stable.
- Inspection never runs repository code (`Package.swift`, Gradle scripts, Tuist manifests).
- Bare SemVer tags (`0.1.0`). Pre-1.0, breaking changes are fine; consumers track `main`.
- No `CHANGELOG.md`; release notes go in GitHub Releases.
