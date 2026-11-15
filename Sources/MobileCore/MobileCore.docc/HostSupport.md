# Host support

The package builds on macOS and Linux. Operations with an explicit host guard report
``MobileKitError/unsupportedHost(_:)`` rather than pretending that the operation succeeded.

## Xcode operations

The explicit `unsupportedHost` paths are Xcode test execution, reading an `.xcresult` through
`NativeResultReader`, and `XcodeToolchain.current(shell:)`. They require macOS and Xcode.
Other Xcode build operations require their command-line tools to be installed and available to
the process; they report the underlying tool error if they cannot run.

## Product boundaries

`MobileCore`, read-only project inspection, and parsing file-based JUnit, Jest, Flutter, and Swift
Testing results do not require Xcode. Android, Flutter, Node/Jest, Gradle, and Bazel operations
depend on the corresponding SDK or executable being installed. Availability of a device still
depends on the host's configured toolchain and connected hardware.

## Topics

- ``MobileKitError``
- ``ToolRunner``
