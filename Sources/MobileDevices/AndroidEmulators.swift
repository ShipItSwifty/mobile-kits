import AVDManagerKit
import AdbKit
import EmulatorKit
import Foundation
import Logging
import MobileCore
import SwiftyShell

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Options for booting an AVD.
public struct EmulatorBootOptions: Sendable, Equatable {
    /// `-no-window -no-audio -no-boot-anim`; required on hosts without a display.
    public var headless: Bool
    public var gpu: String?
    public var snapshot: EmulatorSnapshot
    public var wipeData: Bool
    /// Lets several emulators run from one AVD at once.
    public var readOnly: Bool
    /// Console port (even, 5554–5682). Picks the first free one when `nil`.
    public var port: Int?
    public var additionalArguments: [String]

    public init(
        headless: Bool = false,
        gpu: String? = nil,
        snapshot: EmulatorSnapshot = .loadOnly,
        wipeData: Bool = false,
        readOnly: Bool = false,
        port: Int? = nil,
        additionalArguments: [String] = []
    ) {
        self.headless = headless
        self.gpu = gpu
        self.snapshot = snapshot
        self.wipeData = wipeData
        self.readOnly = readOnly
        self.port = port
        self.additionalArguments = additionalArguments
    }
}

/// An emulator process started by ``AndroidEmulatorManager/start(avd:options:logPath:)``.
///
/// The caller owns it: ``AndroidEmulatorManager/stop(_:)`` stops only emulators this handle
/// describes, never one that was already running.
public struct EmulatorInstance: Sendable, Equatable {
    public var avd: String
    /// `emulator-<port>`.
    public var serial: String
    /// Process id (also its process group: the emulator runs in its own session).
    public var pid: Int32
    public var logPath: String?

    /// Whether the emulator process is still alive. Reaps it when it has exited.
    public func isRunning() -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return false }
        if result == -1, errno == ECHILD { return kill(pid, 0) == 0 }
        return true
    }

    /// The last `lines` lines of the emulator log, for an error message.
    public func logTail(lines: Int = 25) -> String {
        guard let logPath, let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

/// Lists, creates, boots, stops, and recovers Android Virtual Devices.
public struct AndroidEmulatorManager: Sendable {
    private let shell: ShellContext
    private let devices: AndroidDeviceManager
    private let logger = Logger.forType(AndroidEmulatorManager.self)

    public init(shell: ShellContext = .init(), devices: AndroidDeviceManager? = nil) {
        self.shell = shell
        self.devices = devices ?? AndroidDeviceManager(shell: shell)
    }

    // MARK: - AVDs

    /// AVD names (`emulator -list-avds`).
    public func listAVDs() async throws -> [String] {
        let output = try await ToolRunner.run(Emulator(context: shell).list(), timeout: .seconds(30))
        return output.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // The emulator prints INFO/WARNING lines on some hosts before the names.
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") && !$0.hasPrefix("WARNING") && !$0.contains(" ") }
    }

    /// **Mutating**: creates an AVD from an installed system image.
    public func createAVD(name: String, systemImage: String, deviceProfile: String? = nil, force: Bool = false) async throws {
        logger.info("Creating AVD", metadata: ["avd": "\(name)", "image": "\(systemImage)"])
        // avdmanager asks "Do you wish to create a custom hardware profile?"; answer no.
        let command = AVDManager(context: shell)
            .createAVD(name: name, systemImage: systemImage, deviceProfile: deviceProfile, force: force)
            .command()
            .stdin(.string("no\n"))
        try await ToolRunner.run(command.timeout(.seconds(120)), context: shell)
    }

    /// **Mutating**: deletes an AVD.
    public func deleteAVD(name: String) async throws {
        try await ToolRunner.run(AVDManager(context: shell).deleteAVD(name: name), timeout: .seconds(60))
    }

    // MARK: - Running emulators

    /// Serials of running emulators, whether or not this process started them.
    public func runningSerials() async throws -> [String] {
        try await devices.list().filter { $0.kind == .emulator }.map(\.serial)
    }

    /// The AVD a running emulator was started from (`adb emu avd name`).
    public func avdName(ofSerial serial: String) async throws -> String? {
        let output = try await ToolRunner.capture(
            Adb(context: shell).serial(serial).rawArguments(["emu", "avd", "name"]), timeout: .seconds(10))
        return output.stdout.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || $0 == "OK" ? nil : $0 }
    }

    /// The serial of a running emulator started from `avd`, if any.
    public func runningSerial(avd: String) async throws -> String? {
        for serial in try await runningSerials() where try await avdName(ofSerial: serial) == avd {
            return serial
        }
        return nil
    }

    /// Starts `avd` in its own session (so it can outlive the caller) and returns once the
    /// process is launched. Call ``waitUntilBooted(_:timeout:)`` before using it.
    ///
    /// - Parameter logPath: Where emulator output goes; `$TMPDIR/emulator-<port>.log` by default.
    public func start(
        avd: String, options: EmulatorBootOptions = .init(), logPath: String? = nil
    ) async throws
        -> EmulatorInstance
    {
        let port: Int
        if let requested = options.port {
            port = requested
        } else {
            port = try await freeConsolePort()
        }
        let log = logPath ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("emulator-\(port).log")
        logger.info("Starting emulator", metadata: ["avd": "\(avd)", "port": "\(port)", "headless": "\(options.headless)"])
        let emulator = Emulator(context: shell)
            .start(
                avd: avd, headless: options.headless, gpu: options.gpu, snapshot: options.snapshot, wipeData: options.wipeData,
                readOnly: options.readOnly, port: port, additionalArguments: options.additionalArguments
            )
            .stdout(.file(path: log, append: true))
            .stderr(.file(path: log, append: true))
        let pid: Int32
        do {
            pid = try await emulator.spawnDetached()
        } catch let error as ShellError {
            throw ToolRunner.map(error, argv: [emulator.command().executableName] + emulator.command().arguments)
        }
        return EmulatorInstance(avd: avd, serial: "emulator-\(port)", pid: pid, logPath: log)
    }

    /// Waits until the emulator has booted, failing fast if its process exits.
    public func waitUntilBooted(_ instance: EmulatorInstance, timeout: Duration = .seconds(300)) async throws {
        try await devices.waitForBoot(instance.serial, timeout: timeout) {
            instance.isRunning()
                ? nil
                : MobileKitError.processExited(
                    description: "Emulator \(instance.avd)", exitCode: nil, logTail: instance.logTail())
        }
    }

    /// Starts `avd` (or reuses an emulator already running it) and waits for boot.
    ///
    /// - Returns: The serial, and the instance when this call started it (`nil` when reused, so
    ///   the caller does not stop an emulator it does not own).
    public func boot(
        avd: String, options: EmulatorBootOptions = .init(), timeout: Duration = .seconds(300)
    ) async throws
        -> (serial: String, started: EmulatorInstance?)
    {
        if let serial = try await runningSerial(avd: avd) {
            logger.info("Reusing running emulator", metadata: ["avd": "\(avd)", "serial": "\(serial)"])
            try await devices.waitForBoot(serial, timeout: timeout)
            return (serial, nil)
        }
        let instance = try await start(avd: avd, options: options)
        try await waitUntilBooted(instance, timeout: timeout)
        return (instance.serial, instance)
    }

    /// Stops an emulator this caller started: `adb emu kill`, then SIGTERM/SIGKILL to its process
    /// group if it does not exit.
    public func stop(_ instance: EmulatorInstance, grace: Duration = .seconds(20)) async {
        logger.info("Stopping emulator", metadata: ["serial": "\(instance.serial)"])
        _ = try? await ToolRunner.capture(Adb(context: shell).serial(instance.serial).emuKill(), timeout: .seconds(15))
        let poller = Poller(timeout: grace, interval: .milliseconds(500))
        if (try? await poller.until("emulator exit") { instance.isRunning() ? nil : true }) != nil { return }
        kill(-instance.pid, SIGTERM)
        if (try? await Poller(timeout: .seconds(5), interval: .milliseconds(250)).until("emulator exit") {
            instance.isRunning() ? nil : true
        }) != nil {
            return
        }
        logger.warning("Emulator ignored SIGTERM; killing", metadata: ["serial": "\(instance.serial)"])
        kill(-instance.pid, SIGKILL)
    }

    /// Recovers a hung emulator this caller started: stop it, cold boot the same AVD on the same
    /// port, and wait for boot.
    public func recover(
        _ instance: EmulatorInstance, options: EmulatorBootOptions = .init(), timeout: Duration = .seconds(300)
    )
        async throws -> EmulatorInstance
    {
        logger.warning("Recovering emulator with a cold boot", metadata: ["avd": "\(instance.avd)"])
        await stop(instance)
        var coldBoot = options
        coldBoot.snapshot = .disabled
        coldBoot.port = instance.emulatorPort
        let restarted = try await start(avd: instance.avd, options: coldBoot, logPath: instance.logPath)
        try await waitUntilBooted(restarted, timeout: timeout)
        return restarted
    }

    /// The first even console port in 5554–5682 that no running emulator uses.
    func freeConsolePort() async throws -> Int {
        let used = Set(try await devices.list().compactMap(\.emulatorConsolePort))
        guard let port = stride(from: 5554, through: 5682, by: 2).first(where: { !used.contains($0) }) else {
            throw MobileKitError.invalidRequest("No free emulator console port between 5554 and 5682")
        }
        return port
    }
}

extension EmulatorInstance {
    var emulatorPort: Int? { Int(serial.dropFirst("emulator-".count)) }
}
