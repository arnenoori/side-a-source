import Foundation

/// Waits for `condition` to hold, checking every 20 ms. `seconds` is what a quiet machine needs; a loaded one (the
/// whole suite on a Mac at a load average in the hundreds) gets six times as long, and a condition that holds ends the
/// wait at once. Returns whether it held, so assert on the result and a timeout fails with a message instead of hanging.
@discardableResult
func eventually(
    _ seconds: Double = 10, isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool
) async -> Bool {
    let end = Date().addingTimeInterval(seconds * 6)
    while Date() < end {
        if await condition() { return true }
        // swiftlint:disable:next sleep_as_sync_in_tests -- the poll interval itself
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Lets work already queued on the caller's actor (an `async let` that has yet to reach its first wait, a task another
/// call started) run up to its first suspension, without waiting on a clock.
func settle(isolation: isolated (any Actor)? = #isolation) async {
    for _ in 0..<20 { await Task.yield() }
}
