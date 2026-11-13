import Foundation

/// `Duration.seconds` traps on huge values, and these durations come from callers.
func sleep(seconds: Double) async throws {
    let oneYear = 31_536_000.0
    try await Task.sleep(for: .seconds(min(max(seconds, 0), oneYear)))
}
