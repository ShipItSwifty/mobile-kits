import Foundation
import Logging
import MobileCore
import ReactNativeKit
import SwiftyShell

/// The package manager a JavaScript project uses, from its lockfile.
public enum JSPackageManager: String, Codable, Sendable, CaseIterable {
    case pnpm
    case yarn
    case bun
    case npm

    /// `pnpm-lock.yaml`, `yarn.lock`, `bun.lock[b]`, else npm.
    public static func detect(in root: String, fileManager: FileManager = .default) -> JSPackageManager {
        let url = URL(fileURLWithPath: root)
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(name).path) }
        if exists("pnpm-lock.yaml") { return .pnpm }
        if exists("yarn.lock") { return .yarn }
        if exists("bun.lockb") || exists("bun.lock") { return .bun }
        return .npm
    }

    /// How this manager runs a locally installed CLI (`npx`, `yarn`, `pnpm exec`, `bunx`).
    public var packageRunner: JSPackageRunner {
        switch self {
        case .pnpm: .pnpm
        case .yarn: .yarn
        case .bun: .bun
        case .npm: .npx
        }
    }
}

/// A JavaScript project: dependency install and `package.json` scripts, run with the project's
/// own package manager so a project's choices (scripts, manager, lockfile) are respected.
public struct JavaScriptProject: Sendable {
    public let root: String
    public let packageManager: JSPackageManager
    private let shell: ShellContext
    private let logger = Logger.forType(JavaScriptProject.self)

    public init(root: String, shell: ShellContext = .init(), packageManager: JSPackageManager? = nil) {
        self.root = root
        self.shell = shell
        self.packageManager = packageManager ?? .detect(in: root)
    }

    /// The `scripts` entry named `name`, if `package.json` declares it.
    public func script(named name: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scripts = json["scripts"] as? [String: Any]
        else { return nil }
        return scripts[name] as? String
    }

    /// Whether the script invokes Jest, so Jest's flags (`--json`, `--testNamePattern`) apply.
    public func scriptUsesJest(_ name: String) -> Bool {
        script(named: name)?.split(whereSeparator: \.isWhitespace).contains { $0 == "jest" || $0.hasSuffix("/jest") } == true
    }

    /// **Mutating**: installs dependencies when `node_modules` is missing.
    public func installDependenciesIfNeeded() async throws {
        guard !FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("node_modules").path) else {
            return
        }
        logger.info("Installing JavaScript dependencies", metadata: ["manager": "\(packageManager.rawValue)", "root": "\(root)"])
        try await ToolRunner.run(
            Command(packageManager.rawValue).args(["install"]).workingDirectory(root).stdout(.discard).timeout(.seconds(1200)),
            context: shell)
    }

    /// Runs a `package.json` script (`<manager> run <script> -- <arguments>`) and returns its
    /// output whatever the exit status: a failing test script is a result, not an error.
    ///
    /// - Throws: ``MobileKitError/notFound(_:)`` when `package.json` has no such script.
    public func run(script name: String, arguments: [String] = [], environment: [String: String] = [:]) async throws -> ShellOutput {
        try await installDependenciesIfNeeded()
        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("package.json").path),
            script(named: name) == nil
        {
            throw MobileKitError.notFound("No '\(name)' script in \(root)/package.json")
        }
        let command = Command(packageManager.rawValue)
            .args(["run", name] + (arguments.isEmpty ? [] : ["--"] + arguments))
            .workingDirectory(root)
            .env(environment)
            .outputLimit(0)
        do {
            return try await command.run(in: shell)
        } catch let ShellError.exitFailure(_, output) {
            return output
        } catch let error as ShellError {
            throw ToolRunner.map(error, argv: [command.executableName] + command.arguments)
        }
    }
}
