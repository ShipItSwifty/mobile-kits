import Foundation

/// Repeats a check against a monotonic deadline: boot waits, readiness probes, recovery loops.
public struct Poller: Sendable {
    public var timeout: Duration
    public var interval: Duration
    private let sleep: (@Sendable (Duration) async throws -> Void)?

    /// - Parameter sleep: Injected in tests; `nil` uses `Task.sleep(for:)`, so cancellation stops a poll.
    ///
    /// Closure parameters are optional rather than defaulted: with Swift 6.3, a defaulted async
    /// closure argument of a public initializer aborts when invoked from another module.
    public init(
        timeout: Duration,
        interval: Duration = .seconds(1),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.timeout = timeout
        self.interval = interval
        self.sleep = sleep
    }

    /// Calls `check` until it returns a value, `stop` returns an error, or the deadline passes.
    ///
    /// - Parameters:
    ///   - operation: Named in the timeout error.
    ///   - stop: Checked before each attempt; return an error to abort early (for example, the
    ///     emulator process died).
    /// - Throws: ``MobileKitError/timedOut(operation:seconds:)`` when the deadline passes, or the
    ///   error `stop` returned.
    public func until<Value: Sendable>(
        _ operation: String,
        stop: (@Sendable () async -> Error?)? = nil,
        check: @Sendable () async throws -> Value?
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let stop, let error = await stop() { throw error }
            if let value = try await check() { return value }
            guard clock.now.advanced(by: interval) < deadline else {
                let components = timeout.components
                throw MobileKitError.timedOut(
                    operation: operation,
                    seconds: Double(components.seconds) + Double(components.attoseconds) / 1e18
                )
            }
            if let sleep {
                try await sleep(interval)
            } else {
                try await Task.sleep(for: interval)
            }
        }
    }
}
