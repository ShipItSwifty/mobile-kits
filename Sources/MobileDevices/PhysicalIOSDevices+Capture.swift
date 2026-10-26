import DeviceCtlKit
import Foundation
import MobileCore
import SwiftyShell

// `devicectl device capture` and `device copy`: screenshots, recordings, and files.
extension PhysicalIOSDeviceManager {
    // MARK: - Screenshots

    /// Captures a screenshot to `path` (a `.png`) and describes it.
    ///
    /// - Parameter displayUniqueID: A display from ``displays(on:)``; the primary display by default.
    @discardableResult
    public func captureScreenshot(
        on udid: String,
        to path: String,
        displayUniqueID: String? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> CoreDeviceScreenshot {
        logger.info("Capturing device screenshot", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).screenshot(device: udid, destination: path, displayUniqueID: displayUniqueID),
            operation: "capture.screenshot", device: udid, timeout: timeout)
        let screenshot = CoreDeviceScreenshot.parse(response.result, fallbackPath: path)
        logger.info("Captured device screenshot", metadata: ["udid": "\(udid)"])
        return screenshot
    }

    /// Captures a screenshot and returns the PNG, removing the temporary file whether or not it succeeds.
    public func screenshot(on udid: String, displayUniqueID: String? = nil, timeout: Duration = .seconds(60)) async throws -> Data {
        let path = Self.temporaryPath("device_screenshot", extension: "png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await captureScreenshot(on: udid, to: path, displayUniqueID: displayUniqueID, timeout: timeout)
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            logger.error("Screenshot file was not readable", metadata: ["udid": "\(udid)", "error": "\(error)"])
            throw MobileKitError.unexpectedOutput(
                tool: "devicectl device capture screenshot", detail: "no image was written: \(error.localizedDescription)")
        }
    }

    // MARK: - Screen recording

    /// Records the screen for `duration` seconds to `path` (a `.mp4`) and returns when it is saved.
    ///
    /// - Parameters:
    ///   - codec: H.264 by default.
    ///   - maskPolicy: How to treat the device bezel; ignored by default.
    ///   - displayUniqueID: A display from ``displays(on:)``; the primary display by default.
    public func recordScreen(
        on udid: String,
        to path: String,
        duration: Double,
        codec: CoreDeviceCaptureCodec? = nil,
        maskPolicy: CoreDeviceMaskPolicy? = nil,
        displayUniqueID: String? = nil
    ) async throws {
        logger.info("Recording device screen", metadata: ["udid": "\(udid)", "seconds": "\(duration)"])
        try await perform(
            DeviceCtl(context: shell).screenRecord(
                device: udid, destination: path, displayUniqueID: displayUniqueID, codec: codec, maskPolicy: maskPolicy,
                duration: duration),
            operation: "capture.screenRecord", device: udid, timeout: .seconds(duration.rounded(.up) + 60))
        logger.info("Recorded device screen", metadata: ["udid": "\(udid)"])
    }

    /// Starts recording the screen to `path` (a `.mp4`) until ``stopScreenRecording(_:timeout:)``.
    ///
    /// The video is only finalized when the process is interrupted, so stop it through this manager
    /// rather than terminating it.
    public func startScreenRecording(
        on udid: String,
        to path: String,
        codec: CoreDeviceCaptureCodec? = nil,
        maskPolicy: CoreDeviceMaskPolicy? = nil,
        displayUniqueID: String? = nil
    ) async throws -> any SpawnedProcess {
        try await spawn(
            DeviceCtl(context: shell).screenRecord(
                device: udid, destination: path, displayUniqueID: displayUniqueID, codec: codec, maskPolicy: maskPolicy),
            operation: "capture.screenRecord", device: udid)
    }

    /// Interrupts a recording ``startScreenRecording(on:to:codec:maskPolicy:displayUniqueID:)`` started
    /// and waits up to `timeout` for the video to be written.
    public func stopScreenRecording(_ recording: any SpawnedProcess, timeout: Duration = .seconds(30)) async throws {
        _ = try await stop(recording, operation: "capture.screenRecord", timeout: timeout)
    }

    // MARK: - Files

    /// Copies files or directories to a device, skipping unmodified files.
    ///
    /// - Parameters:
    ///   - sources: Host paths to transfer.
    ///   - domain: The device file domain, such as ``CoreDeviceFileDomain/appData(bundleID:)``.
    ///   - destination: The device location, relative to the domain.
    public func copyToDevice(
        sources: [String],
        on udid: String,
        domain: CoreDeviceFileDomain,
        destination: String? = nil,
        options: CoreDeviceCopyOptions = .init(),
        timeout: Duration = .seconds(300)
    ) async throws -> DeviceCtlResponse {
        logger.info("Copying files to device", metadata: ["udid": "\(udid)", "count": "\(sources.count)"])
        let response = try await perform(
            DeviceCtl(context: shell).copyToDevice(
                sources: sources, device: udid, domain: domain, destination: destination, options: options),
            operation: "copy.to", device: udid, timeout: timeout)
        logger.info("Copied files to device", metadata: ["udid": "\(udid)"])
        return response
    }

    /// Copies a file or directory from a device.
    ///
    /// - Parameters:
    ///   - source: The device path, relative to the domain.
    ///   - destination: The host location to copy to.
    public func copyFromDevice(
        source: String,
        on udid: String,
        domain: CoreDeviceFileDomain,
        destination: String? = nil,
        options: CoreDeviceCopyOptions = .init(),
        timeout: Duration = .seconds(300)
    ) async throws -> DeviceCtlResponse {
        logger.info("Copying files from device", metadata: ["udid": "\(udid)"])
        let response = try await perform(
            DeviceCtl(context: shell).copyFromDevice(
                source: source, device: udid, domain: domain, destination: destination, options: options),
            operation: "copy.from", device: udid, timeout: timeout)
        logger.info("Copied files from device", metadata: ["udid": "\(udid)"])
        return response
    }
}
