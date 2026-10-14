# Shared mobile tooling: structure and migration

Decided 2026-10-14. Replaces the earlier six-product proposal.

## Layers

| Layer | Repository | Contents |
| --- | --- | --- |
| 1. Tool wrappers | `ShipItSwifty/cli-wrappers` | One product per CLI: argv only, no policy. |
| 2. Mechanisms | `ShipItSwifty/mobile-kits` | Build, devices, claims, test execution, result parsing, repository inspection. |
| 3. Policies | ShipItSwifty | Retries and flaky classification across attempts, coverage and gates, failure audits, evidence and reporting, telemetry, store submission. |
| Orchestration | Amoo | Companions, MCP, recording, code generation, AI-agent integration. |

Both consumers depend on layers 1 and 2 directly and never on each other. Pre-1.0, consumers
track `main` (`branch: "main"`); bare SemVer tags still mark releases.

## Ownership map

| Moved from | To |
| --- | --- |
| ShipIt `XcodeBuildKit`, `XcodeGenKit`, `AndroidCLIKit`; `GradleKit` (Gradle, adb, emulator, bundletool); ShipItKit `Xcrun/`, `Plutil`, `Frameit`, `SecurityCLI`, `FlutterCLI`, `ReactNativeCLI`, `SwiftPMCLI` | `cli-wrappers` (one product each; `GradleKit` keeps Gradle only) |
| New | `cli-wrappers`: `DeviceCtlKit`, `IProxyKit`, `AVDManagerKit`, `SDKManagerKit`, `CocoaPodsKit`, `TuistCLIKit`, `CodesignKit`, `BazelKit`, `XCResultTool`, Expo |
| ShipIt `TestResults/` parsers and per-run model (`ParsedTestRun`, destinations, selectors) | `MobileTesting` |
| ShipIt `TestRunReport`, `TestAttempt`, reconciliation, evidence, coverage | stay in ShipIt |
| ShipIt `JSONValue`, `BuildSystem` (as `AppFramework`) | `MobileCore` |
| ShipIt `JSPackageManager` / `JSScriptRunner` (mechanism) | `MobileBuild.JavaScriptProject` |
| ShipIt build/archive/export command assembly, artifact discovery | `MobileBuild` |
| ShipIt `SimulatorLease`, Amoo `DeviceLease` + `SessionDeviceClaim` | `MobileDevices.DeviceClaimStore` + `DeviceSessionLock` (same on-disk format) |
| Amoo simctl/adb/emulator/AVD/devicectl/iproxy mechanics, `AndroidJDK`; ShipIt `AndroidDeviceProvisioner` lifecycle | `MobileDevices` |
| ShipIt `BuildSystem.autoDetect`, container discovery; Amoo regex harness discovery | `MobileProject` |

## Status

- [x] `cli-wrappers`: 22 products, argv tests, Linux CI (Swift 6.2 and latest).
- [x] `mobile-kits`: five products, tests on macOS and Linux.
- [x] Amoo depends on `cli-wrappers` and `mobile-kits`, not ShipItSwifty.
- [x] Amoo leases are `DeviceClaimStore` claims (same on-disk format); reads no longer reap.
- [x] Amoo `amoo init` harness discovery uses `MobileProject`'s SwiftSyntax inspector.
- [x] Amoo JDK resolution uses `JavaRuntimes`; devicectl, iproxy, avdmanager argv come from wrappers; `env up` boots through `SimulatorManager`.
- [x] ShipIt depends on both; `BuildSystem` is `AppFramework`, `JSONValue` is MobileCore's.
- [x] ShipIt reads native results through `MobileTesting` and Gradle JUnit/NO-SOURCE through `GradleTestResults`; keeps reports, reconciliation, evidence, coverage.
- [x] ShipIt `SimulatorLease` is policy over `DeviceClaimStore`; `JSScriptRunner` runs on `JavaScriptProject`.
- [x] ShipIt docs, DocC, and the website describe the packages.
- [x] ShipIt build, archive, export, and native-test actions call `XcodeBuilder`/`GradleBuilder`/`XcodeTestRunner` instead of assembling commands (Flutter and React Native keep their `cli-wrappers` families; Gradle test execution and evidence stay ShipIt policy).
- [x] ShipIt `AndroidDeviceProvisioner` boots through `AndroidEmulatorManager` (`EmulatorBootOptions.attached`).
- [ ] Amoo `SimctlRunner`/`ADBRunner`/`EmulatorRunner` delegate to the MobileDevices managers; remaining raw `simctl` calls behind Amoo's process-runner seam move too.
- [ ] Device-level verification (simulator, emulator, physical device) of the migrated paths.
- [ ] Create the GitHub repositories, push, drop local SwiftPM mirrors, and re-resolve consumers so `Package.resolved` records `remoteSourceControl`.

## Rules

- No compatibility aliases or re-exports; consumers import what they use.
- A mechanism returns facts and outcomes; it does not choose retries, exit codes, or messages.
- Artifacts come from what tools report, never from guessed paths.
- Inspection is read-only: it never evaluates `Package.swift`, Gradle scripts, or Tuist manifests.
- Device claim files are a shared interchange format; change them only with a versioned migration.
