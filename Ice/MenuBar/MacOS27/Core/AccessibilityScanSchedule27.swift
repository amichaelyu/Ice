//
//  AccessibilityScanSchedule27.swift
//  Ice
//

import Foundation

/// Decides how long to wait for each process when Ice reads menu bar items
/// through Accessibility on macOS 27.
///
/// Ice asks every running process for its items. Some processes never answer,
/// such as WebKit's content processes, and each costs the whole timeout on every
/// read: measured 17 of them and 8.5 s of a 10 s read. A process that times out
/// is skipped for a while, then asked again with a short timeout.
struct AccessibilityScanSchedule27 {
    static let normalTimeout: Float = 0.5
    static let retryTimeout: Float = 0.1

    private static let firstPause: TimeInterval = 60
    private static let longestPause: TimeInterval = 600

    private var pauses = [pid_t: (failures: Int, retryAt: TimeInterval)]()

    /// The timeout to ask the process with, or `nil` to skip it for now.
    func timeout(for pid: pid_t, now: TimeInterval) -> Float? {
        guard let pause = pauses[pid] else {
            return Self.normalTimeout
        }
        return now >= pause.retryAt ? Self.retryTimeout : nil
    }

    mutating func record(pid: pid_t, timedOut: Bool, now: TimeInterval) {
        guard timedOut else {
            pauses[pid] = nil
            return
        }
        let failures = (pauses[pid]?.failures ?? 0) + 1
        let pause = min(Self.firstPause * pow(2, Double(failures - 1)), Self.longestPause)
        pauses[pid] = (failures, now + pause)
    }

    /// Forgets processes that are no longer running.
    mutating func retain(running pids: Set<pid_t>) {
        pauses = pauses.filter { pids.contains($0.key) }
    }
}
