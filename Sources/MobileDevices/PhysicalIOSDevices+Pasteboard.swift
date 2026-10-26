import DeviceCtlKit
import Foundation
import MobileCore

// `devicectl device pasteboard` and `device notification`.
extension PhysicalIOSDeviceManager {
    // MARK: - Pasteboard

    /// Puts text on the device pasteboard under devicectl's plain-text types.
    ///
    /// The text reaches devicectl through a temporary file passed with `--file` and removed
    /// afterwards, never through argv, so it does not appear in process listings or logs.
    public func copyTextToPasteboard(_ text: String, on udid: String, pasteboard: String? = nil) async throws {
        let path = Self.temporaryPath("device_pasteboard", extension: "txt")
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Pasteboard text could not be staged", metadata: ["udid": "\(udid)", "error": "\(error)"])
            throw MobileKitError.invalidRequest("Could not stage pasteboard text: \(error.localizedDescription)")
        }
        try await copyFilesToPasteboard([path], on: udid, pasteboard: pasteboard)
    }

    /// Puts files on the device pasteboard, one item per file.
    ///
    /// - Parameter type: The UTI of the data, such as `public.png`. Without it devicectl treats each
    ///   file as UTF-8 text and writes it under several text types.
    public func copyFilesToPasteboard(_ paths: [String], type: String? = nil, on udid: String, pasteboard: String? = nil) async throws {
        logger.info("Copying files to device pasteboard", metadata: ["udid": "\(udid)", "count": "\(paths.count)"])
        try await perform(
            DeviceCtl(context: shell).pasteboardCopy(device: udid, type: type, files: paths, pasteboard: pasteboard),
            operation: "pasteboard.copy", device: udid)
        logger.info("Copied files to device pasteboard", metadata: ["udid": "\(udid)"])
    }

    /// Reads one item of the device pasteboard.
    ///
    /// - Parameters:
    ///   - type: The UTI to extract, such as `public.png`; text types are tried in priority order when `nil`.
    ///   - item: The zero-based pasteboard item.
    /// - Returns: The bytes devicectl wrote to stdout, undecoded so image data survives.
    public func pasteboardData(
        on udid: String,
        type: String? = nil,
        item: Int? = nil,
        pasteboard: String? = nil
    ) async throws -> Data {
        logger.info("Reading device pasteboard", metadata: ["udid": "\(udid)"])
        let run = try await performWritingJSONFile(
            DeviceCtl(context: shell).pasteboardPaste(device: udid, type: type, item: item, pasteboard: pasteboard),
            operation: "pasteboard.paste", device: udid)
        logger.info("Read device pasteboard", metadata: ["udid": "\(udid)", "bytes": "\(run.standardOutputData.count)"])
        return run.standardOutputData
    }

    /// The items on the device pasteboard and the types they offer, without transferring any data.
    public func pasteboardInfo(on udid: String, pasteboard: String? = nil) async throws -> CoreDevicePasteboardInfo {
        let response = try await perform(
            DeviceCtl(context: shell).pasteboardInfo(device: udid, pasteboard: pasteboard), operation: "pasteboard.info", device: udid)
        return CoreDevicePasteboardInfo.parse(response.result)
    }

    /// Watches the device pasteboard and returns devicectl's report of the changes seen.
    ///
    /// - Parameter sessionTimeout: Seconds to watch; devicectl defaults to 300.
    public func monitorPasteboard(on udid: String, sessionTimeout: Int? = nil, pasteboard: String? = nil) async throws -> DeviceCtlResponse
    {
        logger.info("Monitoring device pasteboard", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).pasteboardMonitor(device: udid, sessionTimeout: sessionTimeout, pasteboard: pasteboard),
            operation: "pasteboard.monitor", device: udid, timeout: .seconds((sessionTimeout ?? 300) + 60))
        logger.info("Stopped monitoring device pasteboard", metadata: ["udid": "\(udid)"])
        return response
    }

    /// Copies the host pasteboard to the device.
    public func transferPasteboardToDevice(on udid: String, options: CoreDevicePasteboardTransfer = .init()) async throws {
        logger.info("Transferring host pasteboard to device", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).pasteboardTransferToDevice(device: udid, options: options),
            operation: "pasteboard.transfer.to", device: udid)
        logger.info("Transferred host pasteboard to device", metadata: ["udid": "\(udid)"])
    }

    /// Copies the device pasteboard to the host.
    ///
    /// With a data policy that produces promises, devicectl stays alive to fulfil them, so this waits
    /// up to `timeout` and an expired wait is reported as a timeout.
    public func transferPasteboardFromDevice(
        on udid: String,
        options: CoreDevicePasteboardTransfer = .init(),
        timeout: Duration = .seconds(120)
    ) async throws {
        logger.info("Transferring device pasteboard to host", metadata: ["udid": "\(udid)"])
        try await perform(
            DeviceCtl(context: shell).pasteboardTransferFromDevice(device: udid, options: options),
            operation: "pasteboard.transfer.from", device: udid, timeout: timeout)
        logger.info("Transferred device pasteboard to host", metadata: ["udid": "\(udid)"])
    }

    /// Keeps the host and device pasteboards in sync for `options.sessionTimeout` seconds (300 by default).
    public func syncPasteboardWithHost(on udid: String, options: CoreDevicePasteboardSync = .init()) async throws -> DeviceCtlResponse {
        logger.info("Syncing device pasteboard with host", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).pasteboardSyncWithHost(device: udid, options: options),
            operation: "pasteboard.sync", device: udid, timeout: .seconds((options.sessionTimeout ?? 300) + 60))
        logger.info("Stopped syncing device pasteboard with host", metadata: ["udid": "\(udid)"])
        return response
    }

    // MARK: - Darwin notifications

    /// Posts Darwin notifications by name.
    public func postNotifications(_ names: [String], on udid: String) async throws {
        logger.info("Posting device notifications", metadata: ["udid": "\(udid)", "count": "\(names.count)"])
        try await perform(
            DeviceCtl(context: shell).postNotifications(names, device: udid), operation: "notification.post", device: udid)
        logger.info("Posted device notifications", metadata: ["udid": "\(udid)"])
    }

    /// Waits for Darwin notifications and returns devicectl's report of those observed.
    ///
    /// - Parameter sessionTimeout: Seconds to wait; devicectl defaults to 300.
    public func observeNotifications(_ names: [String], on udid: String, sessionTimeout: Int? = nil) async throws -> DeviceCtlResponse {
        logger.info("Observing device notifications", metadata: ["udid": "\(udid)", "count": "\(names.count)"])
        let response = try await perform(
            DeviceCtl(context: shell).observeNotifications(names, device: udid, sessionTimeout: sessionTimeout),
            operation: "notification.observe", device: udid, timeout: .seconds((sessionTimeout ?? 300) + 60))
        logger.info("Stopped observing device notifications", metadata: ["udid": "\(udid)"])
        return response
    }
}
