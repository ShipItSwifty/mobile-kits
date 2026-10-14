# mobile-kits

The mechanisms mobile automation needs, as Swift libraries: build apps across build systems, manage
simulators, emulators, and devices (including recovering hung ones), coordinate device ownership
between tools, run tests, and read every native result format into one model.

Built on the typed command wrappers in [`cli-wrappers`](https://github.com/ShipItSwifty/cli-wrappers).
Used by [ShipItSwifty](https://github.com/ShipItSwifty/shipitswifty) for release automation and by Amoo
for AI-driven device automation. Policies such as test retries, coverage gates, and reporting stay
with those tools.

| Product | Use it to |
| --- | --- |
| `MobileDevices` | List, boot, shut down, erase, and recover iOS Simulators; list Android devices, start and cold-boot emulators, wait for boot, recover offline devices; install, launch, relaunch, and terminate apps; drive physical iOS devices with `devicectl` and forward ports with `iproxy`; claim a device so concurrent tools don't collide; find a JDK in a version range and the active Xcode. |
| `MobileBuild` | Build, build-for-testing, archive, and export with `xcodebuild`; assemble and bundle with Gradle; build Flutter, React Native (CocoaPods, Expo prebuild, Metro), Kotlin Multiplatform, SwiftPM, and Bazel projects; generate projects with XcodeGen or Tuist; verify signatures. Artifacts come from what each tool reports. |
| `MobileTesting` | Run tests with `xcodebuild`, Gradle (unit and connected), `swift test`, `flutter test`, Jest, and `bazel test`, and read `.xcresult`, JUnit XML, Swift Testing events, Flutter machine output, and Jest JSON into `ParsedTestRun`. |
| `MobileProject` | Inspect a repository without running it: Xcode projects and test plans, Swift packages, Gradle modules and application ids, the app framework, Bazel and Tuist markers. Discover a UI-test harness (base class, launch, factory, waits, identifier catalog) with SwiftSyntax. |
| `MobileCore` | Shared types: `MobilePlatform`, `AppFramework`, `BuildBackend`, `MobileKitError`, `Poller`, `JSONValue`. |

## Install

Pre-1.0, track `main`:

```swift
.package(url: "https://github.com/ShipItSwifty/mobile-kits.git", branch: "main"),
```

Swift 6.2+, macOS 15+ or Linux. On Linux, Apple-only operations throw `MobileKitError.unsupportedHost`.

## Examples

```swift
import MobileDevices

let simulators = SimulatorManager()
let phone = try await simulators.list().first { $0.name == "iPhone 16" && $0.osName == "iOS" }!
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
let xctestrun = build.artifacts(.xctestrun).first!
let execution = try await XcodeTestRunner().testWithoutBuilding(
    xctestrun: xctestrun, destination: .simulator(udid: phone.udid), resultBundlePath: "build/run.xcresult")
print(execution.run.summary)
```

## License

MIT
