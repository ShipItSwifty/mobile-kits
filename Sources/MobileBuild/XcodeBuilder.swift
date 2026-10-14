import Foundation
import Logging
import MobileCore
import SwiftyShell
import XcodeBuildKit

/// The project or workspace `xcodebuild` builds. `nil` in a request lets `xcodebuild` pick the
/// single project in the working directory.
public enum XcodeContainer: Sendable, Equatable {
    case project(String)
    case workspace(String)
}

/// Where an Xcode build runs or which platform it targets (`-destination`).
public enum XcodeDestination: Sendable, Equatable {
    /// `generic/platform=iOS Simulator`: builds for every simulator, runs on none.
    case anyIOSSimulator
    /// `generic/platform=iOS`: device builds, for archives.
    case anyIOSDevice
    /// One simulator by UDID.
    case simulator(udid: String)
    /// One physical device by UDID.
    case device(udid: String)
    case macOS
    /// A raw destination specifier, e.g. `platform=iOS Simulator,name=iPhone 16,OS=18.2`.
    case custom(String)

    public var specifier: String {
        switch self {
        case .anyIOSSimulator: "generic/platform=iOS Simulator"
        case .anyIOSDevice: "generic/platform=iOS"
        case .simulator(let udid): "platform=iOS Simulator,id=\(udid)"
        case .device(let udid): "platform=iOS,id=\(udid)"
        case .macOS: "platform=macOS"
        case .custom(let value): value
        }
    }
}

/// What to build with `xcodebuild`.
public struct XcodeBuildRequest: Sendable {
    public var container: XcodeContainer?
    public var scheme: String
    public var configuration: String
    public var destination: XcodeDestination?
    public var sdk: String?
    public var derivedDataPath: String?
    public var resultBundlePath: String?
    /// Build settings passed as `NAME=value`.
    public var buildSettings: [String: String]
    /// Options passed through unchanged, e.g. `-allowProvisioningUpdates` and App Store Connect
    /// authentication-key options a release tool resolved.
    public var additionalOptions: [XcodeBuildOption]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        container: XcodeContainer? = nil,
        scheme: String,
        configuration: String = "Debug",
        destination: XcodeDestination? = nil,
        sdk: String? = nil,
        derivedDataPath: String? = nil,
        resultBundlePath: String? = nil,
        buildSettings: [String: String] = [:],
        additionalOptions: [XcodeBuildOption] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.container = container
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
        self.sdk = sdk
        self.derivedDataPath = derivedDataPath
        self.resultBundlePath = resultBundlePath
        self.buildSettings = buildSettings
        self.additionalOptions = additionalOptions
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// `ExportOptions.plist` for `xcodebuild -exportArchive`.
public struct ExportOptions: Sendable, Equatable {
    /// `app-store-connect`, `release-testing`, `enterprise`, `debugging` (or the older
    /// `app-store`, `ad-hoc`, `development`).
    public var method: String
    public var teamID: String?
    /// `automatic` or `manual`.
    public var signingStyle: String
    /// Bundle id to provisioning profile name or UUID, for manual signing.
    public var provisioningProfiles: [String: String]
    public var signingCertificate: String?
    /// `export` writes an `.ipa`; `upload` sends it to App Store Connect.
    public var destination: String
    public var uploadSymbols: Bool?
    public var manageAppVersionAndBuildNumber: Bool?
    public var stripSwiftSymbols: Bool?
    public var additional: [String: String]

    public init(
        method: String,
        teamID: String? = nil,
        signingStyle: String = "automatic",
        provisioningProfiles: [String: String] = [:],
        signingCertificate: String? = nil,
        destination: String = "export",
        uploadSymbols: Bool? = nil,
        manageAppVersionAndBuildNumber: Bool? = nil,
        stripSwiftSymbols: Bool? = nil,
        additional: [String: String] = [:]
    ) {
        self.method = method
        self.teamID = teamID
        self.signingStyle = signingStyle
        self.provisioningProfiles = provisioningProfiles
        self.signingCertificate = signingCertificate
        self.destination = destination
        self.uploadSymbols = uploadSymbols
        self.manageAppVersionAndBuildNumber = manageAppVersionAndBuildNumber
        self.stripSwiftSymbols = stripSwiftSymbols
        self.additional = additional
    }

    /// The property-list document.
    public func plistData() throws -> Data {
        var dictionary: [String: Any] = ["method": method, "signingStyle": signingStyle, "destination": destination]
        if let teamID { dictionary["teamID"] = teamID }
        if !provisioningProfiles.isEmpty { dictionary["provisioningProfiles"] = provisioningProfiles }
        if let signingCertificate { dictionary["signingCertificate"] = signingCertificate }
        if let uploadSymbols { dictionary["uploadSymbols"] = uploadSymbols }
        if let manageAppVersionAndBuildNumber { dictionary["manageAppVersionAndBuildNumber"] = manageAppVersionAndBuildNumber }
        if let stripSwiftSymbols { dictionary["stripSwiftSymbols"] = stripSwiftSymbols }
        for (key, value) in additional { dictionary[key] = value }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
}

/// Builds, builds for testing, archives, and exports Xcode projects, reporting the products
/// `xcodebuild` itself says it wrote (`-showBuildSettings -json`) instead of scraping the log.
public struct XcodeBuilder: Sendable {
    private let shell: ShellContext
    private let output: BuildOutput
    private let logger = Logger.forType(XcodeBuilder.self)

    public init(shell: ShellContext = .init(), output: BuildOutput = .init()) {
        self.shell = shell
        self.output = output
    }

    /// The `xcodebuild` invocation for `request`, before an action is selected.
    public func command(for request: XcodeBuildRequest) -> XcodeBuild {
        var xcodebuild = XcodeBuild(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
        switch request.container {
        case .project(let path): xcodebuild = xcodebuild.project(path)
        case .workspace(let path): xcodebuild = xcodebuild.workspace(path)
        case nil: break
        }
        xcodebuild = xcodebuild.option(.scheme(request.scheme)).option(.configuration(request.configuration))
        if let destination = request.destination { xcodebuild = xcodebuild.option(.destination(destination.specifier)) }
        if let sdk = request.sdk { xcodebuild = xcodebuild.option(.sdk(sdk)) }
        if let path = request.derivedDataPath { xcodebuild = xcodebuild.option(.derivedDataPath(path)) }
        if let path = request.resultBundlePath { xcodebuild = xcodebuild.option(.resultBundlePath(path)) }
        for option in request.additionalOptions { xcodebuild = xcodebuild.option(option) }
        for (key, value) in request.buildSettings.sorted(by: { $0.key < $1.key }) {
            xcodebuild = xcodebuild.buildSetting(key, value)
        }
        if let directory = request.workingDirectory { xcodebuild = xcodebuild.workingDirectory(directory) }
        if !request.environment.isEmpty { xcodebuild = xcodebuild.env(request.environment) }
        return xcodebuild
    }

    /// `xcodebuild build`, returning the built `.app` bundles and dSYMs.
    public func build(_ request: XcodeBuildRequest, clean: Bool = false) async throws -> BuildOutcome {
        logger.info("xcodebuild build", metadata: ["scheme": "\(request.scheme)", "configuration": "\(request.configuration)"])
        let (log, duration) = try await runBuild(command(for: request).build(clean: clean), backend: .xcodebuild) {
            XcodeBuildLogSummary.parse($0).resultLine
        }
        let products = try await products(for: request)
        return outcome(log, duration: duration, artifacts: products.artifacts, diagnostics: products.diagnostics)
    }

    /// `xcodebuild build-for-testing`, returning the products plus the `.xctestrun` files that
    /// `test-without-building` runs.
    public func buildForTesting(_ request: XcodeBuildRequest) async throws -> BuildOutcome {
        logger.info("xcodebuild build-for-testing", metadata: ["scheme": "\(request.scheme)"])
        let started = Date()
        let (log, duration) = try await runBuild(command(for: request).buildForTesting(), backend: .xcodebuild) {
            XcodeBuildLogSummary.parse($0).resultLine
        }
        let products = try await products(for: request)
        let testRuns = Self.xctestrunFiles(in: products.productsDirectory, modifiedSince: started)
        return outcome(
            log, duration: duration, artifacts: products.artifacts + testRuns.map { BuildArtifact(kind: .xctestrun, path: $0) },
            diagnostics: products.diagnostics + (testRuns.isEmpty ? ["build-for-testing wrote no .xctestrun file"] : []))
    }

    /// `xcodebuild build-for-testing -testProductsPath <path>`: builds the app and test bundles once
    /// into one `.xctestproducts` bundle that ``XcodeTestRunner`` runs any number of times, on any
    /// destination of the same platform, without the project.
    ///
    /// Unlike ``buildForTesting(_:)`` this reads no build settings: the test-products bundle is the
    /// only product, and `testProductsPath` must not exist yet.
    public func buildForTesting(_ request: XcodeBuildRequest, testProductsPath: String) async throws -> BuildOutcome {
        logger.info("xcodebuild build-for-testing", metadata: ["scheme": "\(request.scheme)", "products": "\(testProductsPath)"])
        var resolved = request
        resolved.additionalOptions.append(.testProductsPath(testProductsPath))
        let (log, duration) = try await runBuild(command(for: resolved).buildForTesting(), backend: .xcodebuild) {
            XcodeBuildLogSummary.parse($0).resultLine
        }
        let written = FileManager.default.fileExists(atPath: testProductsPath)
        return outcome(
            log, duration: duration, artifacts: written ? [BuildArtifact(kind: .xctestproducts, path: testProductsPath)] : [],
            diagnostics: written ? [] : ["build-for-testing wrote no .xctestproducts bundle to \(testProductsPath)"])
    }

    /// `xcodebuild archive -archivePath <path>`.
    public func archive(_ request: XcodeBuildRequest, archivePath: String) async throws -> BuildOutcome {
        logger.info("xcodebuild archive", metadata: ["scheme": "\(request.scheme)", "archive": "\(archivePath)"])
        let (log, duration) = try await runBuild(command(for: request).archive(path: archivePath), backend: .xcodebuild) {
            XcodeBuildLogSummary.parse($0).resultLine
        }
        var artifacts = [BuildArtifact(kind: .xcarchive, path: archivePath)]
        let dsyms = (archivePath as NSString).appendingPathComponent("dSYMs")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dsyms))?.sorted() ?? [] where name.hasSuffix(".dSYM") {
            artifacts.append(BuildArtifact(kind: .dsym, path: (dsyms as NSString).appendingPathComponent(name)))
        }
        return outcome(log, duration: duration, artifacts: artifacts)
    }

    /// `xcodebuild -exportArchive`, writing `options` to a temporary plist.
    ///
    /// - Parameter additionalOptions: Passed through unchanged, e.g. `-allowProvisioningUpdates` and
    ///   App Store Connect authentication-key options for automatic signing.
    public func exportArchive(
        archivePath: String,
        exportPath: String,
        options: ExportOptions,
        additionalOptions: [XcodeBuildOption] = []
    ) async throws -> BuildOutcome {
        logger.info("xcodebuild -exportArchive", metadata: ["archive": "\(archivePath)", "method": "\(options.method)"])
        let plist = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ExportOptions-\(UUID().uuidString).plist")
        try options.plistData().write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        var xcodebuild = XcodeBuild(context: shell)
            .settingStdoutDestination(output.stdout)
            .settingStderrDestination(output.stderr)
        for option in additionalOptions { xcodebuild = xcodebuild.option(option) }
        let family = xcodebuild.exportArchive(archivePath: archivePath, exportPath: exportPath, exportOptionsPlist: plist.path)
        let (log, duration) = try await runBuild(family, backend: .xcodebuild) { XcodeBuildLogSummary.parse($0).resultLine }
        let ipas = ((try? FileManager.default.contentsOfDirectory(atPath: exportPath)) ?? []).sorted().filter { $0.hasSuffix(".ipa") }
        return outcome(
            log, duration: duration,
            artifacts: ipas.map { BuildArtifact(kind: .ipa, path: (exportPath as NSString).appendingPathComponent($0)) },
            diagnostics: ipas.isEmpty && options.destination == "export" ? ["export wrote no .ipa to \(exportPath)"] : [])
    }

    // MARK: - Products

    /// Build settings per target, from `xcodebuild -showBuildSettings -json`.
    public func buildSettings(for request: XcodeBuildRequest) async throws -> [XcodeTargetSettings] {
        var quiet = request
        quiet.resultBundlePath = nil
        let family = command(for: quiet).settingStdoutDestination(.capture).settingStderrDestination(.capture).showBuildSettings(json: true)
        let result = try await ToolRunner.run(family, timeout: .seconds(180))
        return try XcodeTargetSettings.parse(result.stdout)
    }

    struct Products {
        var artifacts: [BuildArtifact]
        var productsDirectory: String?
        var diagnostics: [String]
    }

    private func products(for request: XcodeBuildRequest) async throws -> Products {
        let targets: [XcodeTargetSettings]
        do {
            targets = try await buildSettings(for: request)
        } catch {
            logger.error("Could not read build settings", metadata: ["scheme": "\(request.scheme)", "error": "\(error)"])
            return Products(
                artifacts: [], productsDirectory: nil, diagnostics: ["Could not read build settings: \(error.localizedDescription)"])
        }
        var artifacts: [BuildArtifact] = []
        for target in targets {
            if let app = target.applicationPath, FileManager.default.fileExists(atPath: app) {
                artifacts.append(BuildArtifact(kind: .app, path: app))
            }
            if let dsym = target.dsymPath, FileManager.default.fileExists(atPath: dsym) {
                artifacts.append(BuildArtifact(kind: .dsym, path: dsym))
            }
        }
        return Products(
            artifacts: Array(Set(artifacts)).sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
            productsDirectory: targets.compactMap { $0.settings["SYMROOT"] }.first, diagnostics: [])
    }

    static func xctestrunFiles(in directory: String?, modifiedSince date: Date) -> [String] {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().filter { $0.hasSuffix(".xctestrun") }.map { (directory as NSString).appendingPathComponent($0) }
            .filter {
                let modified = (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
                return (modified ?? .distantFuture) >= date.addingTimeInterval(-1)
            }
    }

    private func outcome(_ log: ShellOutput, duration: Double, artifacts: [BuildArtifact], diagnostics: [String] = []) -> BuildOutcome {
        let summary = XcodeBuildLogSummary.parse(log.stdout + "\n" + log.stderr)
        return BuildOutcome(
            backend: .xcodebuild, artifacts: artifacts, warnings: summary.warningCount, errors: summary.errorCount,
            resultLine: summary.resultLine, durationSeconds: duration, output: log, diagnostics: diagnostics)
    }
}

/// One target's resolved build settings.
public struct XcodeTargetSettings: Sendable, Equatable {
    public var target: String
    public var action: String?
    public var settings: [String: String]

    /// `TARGET_BUILD_DIR/FULL_PRODUCT_NAME` for application targets.
    public var applicationPath: String? {
        guard settings["WRAPPER_EXTENSION"] == "app" || settings["PRODUCT_TYPE"] == "com.apple.product-type.application",
            let directory = settings["TARGET_BUILD_DIR"], let name = settings["FULL_PRODUCT_NAME"] ?? settings["WRAPPER_NAME"]
        else { return nil }
        return (directory as NSString).appendingPathComponent(name)
    }

    /// `DWARF_DSYM_FOLDER_PATH/DWARF_DSYM_FILE_NAME`.
    public var dsymPath: String? {
        guard let directory = settings["DWARF_DSYM_FOLDER_PATH"], let name = settings["DWARF_DSYM_FILE_NAME"] else { return nil }
        return (directory as NSString).appendingPathComponent(name)
    }

    public var bundleIdentifier: String? { settings["PRODUCT_BUNDLE_IDENTIFIER"] }

    /// Parses `xcodebuild -showBuildSettings -json`.
    public static func parse(_ json: String) throws -> [XcodeTargetSettings] {
        // xcodebuild can print warnings before the JSON array.
        let start = json.firstIndex(of: "[") ?? json.startIndex
        guard let array = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [[String: Any]] else {
            throw MobileKitError.unexpectedOutput(tool: "xcodebuild -showBuildSettings -json", detail: String(json.prefix(200)))
        }
        return array.map { entry in
            let raw = entry["buildSettings"] as? [String: Any] ?? [:]
            var settings: [String: String] = [:]
            for (key, value) in raw {
                settings[key] = value as? String ?? "\(value)"
            }
            return XcodeTargetSettings(target: entry["target"] as? String ?? "", action: entry["action"] as? String, settings: settings)
        }
    }
}
