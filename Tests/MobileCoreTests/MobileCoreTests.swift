import Foundation
import SwiftyShell
import Synchronization
import Testing

@testable import MobileCore

@Suite("MobileCore")
struct MobileCoreTests {
    @Test("Poller returns the first value and times out with the operation name")
    func poller() async throws {
        let attempts = Mutex(0)
        let poller = Poller(timeout: .seconds(5), interval: .milliseconds(1), sleep: { _ in })
        let value = try await poller.until("thing") { () -> Int? in
            attempts.withLock { count in
                count += 1
                return count == 3 ? 42 : nil
            }
        }
        #expect(value == 42)
        await #expect(throws: MobileKitError.self) {
            _ = try await Poller(timeout: .milliseconds(20), interval: .milliseconds(5)).until("never") { () -> Int? in nil }
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
