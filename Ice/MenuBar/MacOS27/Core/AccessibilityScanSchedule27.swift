//
//  AccessibilityScanSchedule27.swift
//  Ice
//

import Foundation

/// Decides which processes Ice asks for menu bar items through Accessibility on
/// macOS 27, and how long it waits for each.
///
/// Most processes have no items, and asking every one of them on every read cost
/// seconds (measured 10 s, 8.5 s of it waiting on processes that never answer). So
/// only the processes known to own items are asked on every read. Any other process
/// is asked during its first seconds, while its item may still appear, and then
/// again only in a sweep of every process, once a minute. A process that does not
/// answer is left out until the next sweep, which asks it with a short timeout. A
/// process that has shown items is always asked: a busy MenuBarAgent or item owner
/// would otherwise lose its items, and the clock its click.
struct AccessibilityScanSchedule27 {
    static let normalTimeout: Float = 0.5
    static let retryTimeout: Float = 0.1

    /// How often every running process is asked.
    static let sweepInterval: TimeInterval = 60
    /// How long a process that started after the first sweep is asked on every read.
    static let launchInterval: TimeInterval = 15

    /// Processes that have published menu bar items.
    private(set) var itemOwners = Set<pid_t>()
    private var unanswered = Set<pid_t>()
    private var launchedAt = [pid_t: TimeInterval]()
    private var running = Set<pid_t>()
    private var lastSweepAt: TimeInterval?

    /// Whether the next read should ask every running process.
    func isSweepDue(now: TimeInterval) -> Bool {
        lastSweepAt.map { now - $0 >= Self.sweepInterval } ?? true
    }

    /// The timeout to ask the process with, or `nil` to leave it out of this read.
    ///
    /// - Parameter sweeping: Whether this read asks every process, or this one by name.
    func timeout(for pid: pid_t, sweeping: Bool, now: TimeInterval) -> Float? {
        if itemOwners.contains(pid) {
            return Self.normalTimeout
        }
        if unanswered.contains(pid) {
            return sweeping ? Self.retryTimeout : nil
        }
        if sweeping {
            return Self.normalTimeout
        }
        guard let launchedAt = launchedAt[pid], now - launchedAt < Self.launchInterval else {
            return nil
        }
        return Self.normalTimeout
    }

    /// Notes the running processes, forgetting the ones that exited.
    mutating func update(running pids: Set<pid_t>, now: TimeInterval) {
        if lastSweepAt != nil {
            for pid in pids.subtracting(running) {
                launchedAt[pid] = now
            }
        }
        running = pids
        launchedAt = launchedAt.filter { pids.contains($0.key) }
        itemOwners.formIntersection(pids)
        unanswered.formIntersection(pids)
    }

    mutating func record(pid: pid_t, timedOut: Bool, hasItems: Bool) {
        if hasItems {
            itemOwners.insert(pid)
        }
        if timedOut, !itemOwners.contains(pid) {
            unanswered.insert(pid)
        } else {
            unanswered.remove(pid)
        }
    }

    mutating func recordSweep(now: TimeInterval) {
        lastSweepAt = now
    }
}
