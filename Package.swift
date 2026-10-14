// swift-tools-version: 6.2

import PackageDescription

let swiftyShell: Target.Dependency = .product(name: "SwiftyShell", package: "SwiftyShell")
let logging: Target.Dependency = .product(name: "Logging", package: "swift-log")

func wrapper(_ name: String) -> Target.Dependency {
    .product(name: name, package: "cli-wrappers")
}

let package = Package(
    name: "MobileKits",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MobileCore", targets: ["MobileCore"]),
        .library(name: "MobileDevices", targets: ["MobileDevices"]),
        .library(name: "MobileBuild", targets: ["MobileBuild"]),
        .library(name: "MobileTesting", targets: ["MobileTesting"]),
        .library(name: "MobileProject", targets: ["MobileProject"]),
    ],
    dependencies: [
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", from: "0.7.0"),
        // Typed tool wrappers. Tracks main until cli-wrappers reaches 1.0.
        .package(url: "https://github.com/ShipItSwifty/cli-wrappers.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        // Swift source inspection, used only by MobileProject.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/maniramezan/SwiftTestCommons.git", from: "0.4.0"),
    ],
    targets: [
        /// Shared value types (platforms, devices, artifacts), errors, and command execution.
        .target(name: "MobileCore", dependencies: [swiftyShell, logging]),
        /// Device inventory, lifecycle, recovery, leases, and toolchain discovery.
        .target(
            name: "MobileDevices",
            dependencies: [
                "MobileCore", swiftyShell, logging,
                wrapper("XcrunKit"), wrapper("DeviceCtlKit"), wrapper("IProxyKit"), wrapper("XcodeBuildKit"),
                wrapper("AdbKit"), wrapper("EmulatorKit"), wrapper("AVDManagerKit"),
            ]
        ),
        /// Building, archiving, exporting, and signing apps across build systems.
        .target(
            name: "MobileBuild",
            dependencies: [
                "MobileCore", swiftyShell, logging,
                wrapper("XcodeBuildKit"), wrapper("XcrunKit"), wrapper("XcodeGenKit"), wrapper("TuistCLIKit"),
                wrapper("CocoaPodsKit"), wrapper("CodesignKit"), wrapper("GradleKit"), wrapper("BundletoolKit"),
                wrapper("FlutterKit"), wrapper("ReactNativeKit"), wrapper("SwiftPMKit"), wrapper("BazelKit"),
            ]
        ),
        /// Running tests and parsing native results into one model.
        .target(
            name: "MobileTesting",
            dependencies: [
                "MobileCore", "MobileBuild", swiftyShell, logging,
                wrapper("XcodeBuildKit"), wrapper("XcrunKit"), wrapper("GradleKit"), wrapper("FlutterKit"),
                wrapper("SwiftPMKit"), wrapper("BazelKit"),
            ]
        ),
        /// Read-only repository inspection: projects, targets, frameworks, and UI-test harnesses.
        .target(
            name: "MobileProject",
            dependencies: [
                "MobileCore", swiftyShell, logging, wrapper("XcodeBuildKit"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .testTarget(name: "MobileCoreTests", dependencies: ["MobileCore", swiftyShell]),
        .testTarget(
            name: "MobileDevicesTests",
            dependencies: ["MobileDevices", swiftyShell, .product(name: "TestCommons", package: "SwiftTestCommons")]
        ),
        .testTarget(
            name: "MobileBuildTests",
            dependencies: ["MobileBuild", swiftyShell, .product(name: "TestCommons", package: "SwiftTestCommons")]
        ),
        .testTarget(
            name: "MobileTestingTests",
            dependencies: ["MobileTesting", swiftyShell, .product(name: "TestCommons", package: "SwiftTestCommons")],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MobileProjectTests",
            dependencies: ["MobileProject", .product(name: "TestCommons", package: "SwiftTestCommons")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
