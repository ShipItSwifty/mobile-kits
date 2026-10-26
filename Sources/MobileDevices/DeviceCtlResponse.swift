import Foundation
import MobileCore
import SwiftyShell

/// A decoded `devicectl --json-output` document from a command that succeeded.
///
/// devicectl's JSON is versioned and stable across releases, unlike its console output. Operations
/// whose result shape is modelled return typed values; the rest return this, so every devicectl
/// result stays reachable.
public struct DeviceCtlResponse: Sendable, Equatable {
    /// The command that produced it, such as `devicectl.device.info.apps`.
    public var commandType: String
    /// The version of the JSON schema.
    public var jsonVersion: Int
    /// The devicectl build that wrote it.
    public var devicectlVersion: String?
    /// The command's `result` object, `.null` for commands that report nothing.
    public var result: JSONValue

    public init(commandType: String, jsonVersion: Int = 0, devicectlVersion: String? = nil, result: JSONValue = .null) {
        self.commandType = commandType
        self.jsonVersion = jsonVersion
        self.devicectlVersion = devicectlVersion
        self.result = result
    }

    /// Reads devicectl's result from the output of a finished run.
    ///
    /// A failed command still writes JSON, so a CoreDevice error is reported as
    /// ``MobileKitError/coreDeviceFailed(_:)`` with its code. Output with no JSON at all is a
    /// ``MobileKitError/commandFailed(command:exitCode:output:)`` on a non-zero exit, and an
    /// ``MobileKitError/unexpectedOutput(tool:detail:)`` otherwise.
    static func decode(json: String, output: ShellOutput, argv: [String]) throws -> DeviceCtlResponse {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
            let info = document["info"]?.objectValue
        else {
            if output.exitCode != 0 {
                let text = [output.stderr, output.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                throw MobileKitError.commandFailed(command: argv, exitCode: output.exitCode, output: text)
            }
            throw MobileKitError.unexpectedOutput(tool: "devicectl", detail: "no JSON result was written")
        }
        let outcome = info["outcome"]?.stringValue
        if outcome != "success" || output.exitCode != 0 {
            throw MobileKitError.coreDeviceFailed(failure(from: document["error"], output: output, argv: argv))
        }
        return DeviceCtlResponse(
            commandType: info["commandType"]?.stringValue ?? "",
            jsonVersion: info["jsonVersion"]?.intValue ?? 0,
            devicectlVersion: info["version"]?.stringValue,
            result: document["result"] ?? .null
        )
    }

    /// Builds the failure from devicectl's `error` object, whose `userInfo` values are wrapped in a
    /// one-key object naming their type (`{"string": "…"}`).
    static func failure(from error: JSONValue?, output: ShellOutput, argv: [String]) -> CoreDeviceFailure {
        let userInfo = error?["userInfo"]?.objectValue ?? [:]
        func text(_ key: String) -> String? {
            userInfo[key]?["string"]?.stringValue
        }
        let fallback = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoreDeviceFailure(
            code: error?["code"]?.intValue ?? Int(output.exitCode),
            domain: error?["domain"]?.stringValue ?? CoreDeviceFailure.coreDeviceDomain,
            message: text("NSLocalizedDescription") ?? (fallback.isEmpty ? "devicectl failed" : fallback),
            reason: text("NSLocalizedFailureReason"),
            capability: text("CapabilityName"),
            deviceIdentifier: text("DeviceIdentifier"),
            command: argv
        )
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Follows `keys` through nested objects.
    func value(at keys: String...) -> JSONValue? {
        var current: JSONValue? = self
        for key in keys {
            current = current?[key]
        }
        return current
    }

    /// An integer or floating-point value as a `Double`.
    var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    /// An integer, also accepting a whole-number floating-point value.
    var wholeNumberValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }
}
