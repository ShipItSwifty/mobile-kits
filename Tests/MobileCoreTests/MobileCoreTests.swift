import Foundation
import SwiftyShell
import Synchronization
import Testing

@testable import MobileCore

@Suite("MobileCore")
struct MobileCoreTests {
    /// A shared counter. Kept in a class: Swift 6.3 on macOS aborts when a non-escaping async
    /// closure captures a noncopyable `Mutex` local directly.
    final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() -> Int {
            value.withLock { count in
                count += 1
                return count
            }
        }
    }

    @Test("Poller returns the first value a check produces")
    func pollerReturnsValue() async throws {
        let attempts = Counter()
        let poller = Poller(timeout: .seconds(5), interval: .milliseconds(1), sleep: { _ in })
        let value = try await poller.until("thing") { () -> Int? in
            attempts.increment() == 3 ? 42 : nil
        }
        #expect(value == 42)
    }

    @Test("Poller times out with the operation name")
    func pollerTimesOut() async {
        await #expect(throws: MobileKitError.self) {
            _ = try await Poller(timeout: .milliseconds(20), interval: .milliseconds(5)).until("never") { () -> Int? in nil }
        }
    }

    @Test("Poller stops early with the stop check's error")
    func pollerStops() async {
        await #expect(throws: MobileKitError.invalidRequest("stop")) {
            _ = try await Poller(timeout: .seconds(5), interval: .milliseconds(1), sleep: { _ in })
                .until("stopping", stop: { MobileKitError.invalidRequest("stop") }, check: { () -> Int? in nil })
        }
    }

    @Test("ToolRunner maps a non-zero exit to commandFailed with argv and trimmed output")
    func mapsExitFailure() async {
        let executor = MockExecutor { _, _ in ShellOutput(stdout: "partial\n", stderr: "boom\n", exitCode: 2) }
        await #expect(throws: MobileKitError.commandFailed(command: ["tool", "a"], exitCode: 2, output: "boom\npartial")) {
            try await ToolRunner.run(Command("tool").args(["a"]), context: ShellContext(executor: executor))
        }
    }

    @Test("Lenient platform decoding")
    func platform() {
        #expect(MobilePlatform(lenient: "iOS") == .ios)
        #expect(MobilePlatform(lenient: "Android") == .android)
        #expect(MobilePlatform(lenient: "web") == nil)
        #expect(DeviceIdentity(platform: .ios, id: "U").description == "ios:U")
    }
}
