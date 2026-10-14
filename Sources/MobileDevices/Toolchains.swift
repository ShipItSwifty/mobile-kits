import Foundation
import Logging
import MobileCore
import SwiftyShell
import XcodeBuildKit

/// An installed JDK.
public struct JavaRuntime: Sendable, Equatable {
    /// The directory `JAVA_HOME` should point to.
    public var home: String
    public var majorVersion: Int

    public init(home: String, majorVersion: Int) {
        self.home = home
        self.majorVersion = majorVersion
    }
}

/// Finds installed JDKs and picks one inside a caller-supplied version range.
///
/// The range belongs to the caller: it is whatever its Android Gradle Plugin and Gradle versions
/// accept, so nothing here hard-codes one.
public struct JavaRuntimes: Sendable {
    public var searchPaths: [String]

    public init(searchPaths: [String] = Self.defaultSearchPaths()) {
        self.searchPaths = searchPaths
    }

    /// macOS: `/Library/Java/JavaVirtualMachines` and the user's copy. Linux: `/usr/lib/jvm`.
    public static func defaultSearchPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        #if os(macOS)
        ["/Library/Java/JavaVirtualMachines", homeDirectory + "/Library/Java/JavaVirtualMachines"]
        #else
        ["/usr/lib/jvm", homeDirectory + "/.sdkman/candidates/java"]
        #endif
    }

    /// Every JDK found in ``searchPaths``.
    public func installed(fileManager: FileManager = .default) -> [JavaRuntime] {
        searchPaths.flatMap { root -> [JavaRuntime] in
            let entries = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            return entries.sorted().compactMap { entry in
                // macOS bundles keep the home under Contents/Home; Linux installs are the home.
                for home in [root + "/" + entry + "/Contents/Home", root + "/" + entry] {
                    if let version = Self.majorVersion(ofJavaHome: home, fileManager: fileManager) {
                        return JavaRuntime(home: home, majorVersion: version)
                    }
                }
                return nil
            }
        }
    }

    /// The `JAVA_HOME` to use for `supported` versions: the caller's own `JAVA_HOME` when it is
    /// in range (a deliberate choice outranks scanning), else the newest installed in range.
    public func resolveJavaHome(
        supported: ClosedRange<Int>,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let current = environment["JAVA_HOME"],
            let version = Self.majorVersion(ofJavaHome: current, fileManager: fileManager),
            supported.contains(version)
        {
            return current
        }
        return installed(fileManager: fileManager)
            .filter { supported.contains($0.majorVersion) }
            .max { $0.majorVersion < $1.majorVersion }?
            .home
    }

    /// `environment` with `JAVA_HOME` replaced when the current one is outside `supported` and a
    /// supported JDK was found.
    public func environment(
        supported: ClosedRange<Int>,
        base environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let home = resolveJavaHome(supported: supported, environment: environment, fileManager: fileManager) else {
            return environment
        }
        var updated = environment
        updated["JAVA_HOME"] = home
        return updated
    }

    /// The major version from a JDK's `release` file (`JAVA_VERSION="21.0.12"`, or `"1.8.0_402"` for 8).
    public static func majorVersion(ofJavaHome home: String, fileManager: FileManager = .default) -> Int? {
        let release = home + "/release"
        guard fileManager.fileExists(atPath: release), let contents = try? String(contentsOfFile: release, encoding: .utf8)
        else { return nil }
        for line in contents.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
            let raw = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            let components = raw.split(separator: ".")
            guard let first = components.first, let major = Int(first) else { return nil }
            return major == 1 && components.count > 1 ? Int(components[1]) : major
        }
        return nil
    }
}

/// The active Xcode installation.
public struct XcodeToolchain: Sendable, Equatable {
    /// `xcode-select -p`, e.g. `/Applications/Xcode.app/Contents/Developer`.
    public var developerDirectory: String
    /// `26.4`.
    public var version: String
    /// `17E192`.
    public var build: String?

    /// Reads the active Xcode, or throws ``MobileKitError/unsupportedHost(_:)`` when there is none.
    public static func current(shell: ShellContext = .init()) async throws -> XcodeToolchain {
        #if !os(macOS)
        throw MobileKitError.unsupportedHost("Xcode is only available on macOS")
        #else
        let path = try await ToolRunner.run(XcodeSelect(context: shell).printPath(), timeout: .seconds(15))
        let version = try await ToolRunner.run(XcodeBuild(context: shell).option(.version), timeout: .seconds(30))
        guard let parsed = parseVersion(version.stdout) else {
            throw MobileKitError.unexpectedOutput(tool: "xcodebuild -version", detail: version.stdout)
        }
        return XcodeToolchain(
            developerDirectory: path.stdout.trimmingCharacters(in: .whitespacesAndNewlines), version: parsed.version,
            build: parsed.build)
        #endif
    }

    /// Parses `Xcode 26.4\nBuild version 17E192`.
    public static func parseVersion(_ output: String) -> (version: String, build: String?)? {
        var version: String?
        var build: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Xcode ") { version = String(line.dropFirst("Xcode ".count)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("Build version ") {
                build = String(line.dropFirst("Build version ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return version.map { ($0, build) }
    }
}
