# mobile-kits

[![CI](https://github.com/ShipItSwifty/mobile-kits/actions/workflows/ci.yml/badge.svg)](https://github.com/ShipItSwifty/mobile-kits/actions/workflows/ci.yml)
[![Documentation](https://github.com/ShipItSwifty/mobile-kits/actions/workflows/docs.yml/badge.svg)](https://shipitswifty.github.io/mobile-kits/documentation/)
![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)

The mechanisms mobile automation needs, as Swift libraries: build apps across build systems, manage
simulators, emulators, and devices (including recovering hung ones), coordinate device ownership
between tools, run tests, and read every native result format into one model.

Built on the typed command wrappers in [`cli-wrappers`](https://github.com/ShipItSwifty/cli-wrappers).
Used by [ShipItSwifty](https://github.com/ShipItSwifty/shipitswifty) for release automation and by Amoo
for AI-driven device automation. Policies such as test retries, coverage gates, and reporting stay
with those tools.

| Product | Use it to |
| --- | --- |
| `MobileDevices` | List, boot, shut down, erase, and recover iOS Simulators; list Android devices, start and cold-boot emulators, wait for boot, recover offline devices; install, launch, relaunch, and terminate apps; drive physical iOS devices, and Xcode 27 simulators, through every `devicectl` command (apps, processes, files, screenshots and recordings, settings, location and status bar simulation, pasteboard, profiles, pairing, diagnostics) and forward ports with `iproxy`; claim a device so concurrent tools don't collide; find a JDK in a version range and the active Xcode. |
| `MobileBuild` | Build, build-for-testing, archive, and export with `xcodebuild`; assemble and bundle with Gradle; build Flutter, React Native (CocoaPods, Expo prebuild, Metro), Kotlin Multiplatform, SwiftPM, and Bazel projects; generate projects with XcodeGen or Tuist; verify signatures. Artifacts come from what each tool reports. |
| `MobileTesting` | Run tests with `xcodebuild`, Gradle (unit and connected), `swift test`, `flutter test`, Jest, and `bazel test`, and read `.xcresult`, JUnit XML, Swift Testing events, Flutter machine output, and Jest JSON into `ParsedTestRun`. |
| `MobileProject` | Inspect a repository without running it: Xcode projects and test plans, Swift packages, Gradle modules and application ids, the app framework, Bazel and Tuist markers. Discover a UI-test harness (base class, launch, factory, waits, identifier catalog) with SwiftSyntax. |
| `MobileCore` | Shared types: `MobilePlatform`, `AppFramework`, `BuildBackend`, `MobileKitError`, `Poller`, `JSONValue`. |

## Install

Pre-1.0, track `main`:

```swift
.package(url: "https://github.com/ShipItSwifty/mobile-kits.git", branch: "main"),
```

Swift 6.2+, macOS 15+ or Linux. CI tests with Xcode 26.4 on macOS and Swift 6.2 and 6.4 on Linux;
the package does not pin a minimum version for Android SDK tools or `iproxy`, so use versions
compatible with the operations you call. On Linux, explicitly host-guarded Apple-only operations
throw `MobileKitError.unsupportedHost`.

Install the tools used by the operations you call: Xcode (including `xcodebuild`, `simctl`,
`devicectl`, and `xcresulttool`) for Apple builds and results; Android SDK Platform-Tools (`adb`)
and, for emulators, Android Emulator and command-line tools; and `iproxy` for USB port forwarding.
Flutter, Node/Jest, Gradle, and Bazel operations also require their respective toolchains.

## Examples

```swift
import MobileDevices

let simulators = SimulatorManager()
guard let phone = try await simulators.list().first(where: { $0.name == "iPhone 16" && $0.osName == "iOS" }) else {
    fatalError("No iPhone 16 simulator")
}
if try await simulators.boot(phone.udid) == .booted { /* this call booted it; shut it down later */ }
if await !simulators.isResponsive(phone.udid) {
    _ = try await simulators.recover(phone.udid)
}

let emulators = AndroidEmulatorManager()
let (serial, started) = try await emulators.boot(avd: "Pixel_8_API_35", options: .init(headless: true))
defer { if let started { Task { await emulators.stop(started) } } }

let claims = DeviceClaimStore(directory: DeviceClaimStore.sharedDirectory())
let claim = try claims.acquire(platform: .android, deviceID: serial, owner: "nightly")
defer { claims.release(claim) }
```

```swift
import MobileBuild
import MobileTesting

let build = try await XcodeBuilder(output: .streaming).buildForTesting(
    XcodeBuildRequest(container: .workspace("App.xcworkspace"), scheme: "App", destination: .anyIOSSimulator))
guard let xctestrun = build.artifacts(.xctestrun).first else { fatalError("build-for-testing wrote no .xctestrun") }
let execution = try await XcodeTestRunner().testWithoutBuilding(
    xctestrun: xctestrun, destination: .simulator(udid: phone.udid), resultBundlePath: "build/run.xcresult")
print(execution.run.summary)
```

For a connected physical iOS device, list available devices and install a built app. Installation
changes device state; `uninstall` is also available on the manager.

```swift
import MobileDevices

let devices = try await PhysicalIOSDeviceManager().list(connectedOnly: true)
if let phone = devices.first {
    let manager = PhysicalIOSDeviceManager()
    let response = try await manager.install(appAt: "build/App.app", on: phone.udid)
    print(response.commandType)
}
```

Read an existing test artifact without choosing its parser yourself:

```swift
import MobileTesting

let run = try await NativeResultReader().read("build/run.xcresult")
print(run.summary)
```

Inspect a repository without executing its build scripts:

```swift
import MobileProject

let inspection = RepositoryInspector().inspect("/path/to/project")
for candidate in inspection.frameworks {
    print(candidate.value, candidate.evidence)
}
```

**Errors:** core and device operations report `MobileKitError`; build operations throw
`BuildFailure` when a build ran but failed; test runners throw `TestExecutionFailure` when no
usable test results were produced. Test failures themselves remain in `TestExecution.run`.

## Documentation

API documentation: <https://shipitswifty.github.io/mobile-kits/documentation/>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
