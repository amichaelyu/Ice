//
//  WritePacer27.swift
//  Ice
//

import Foundation

/// Spaces out the writes of MenuBarAgent's "Allow in the Menu Bar" preference.
///
/// A lone write fades only the affected items, in about 250 ms. Two writes close together do
/// not: measured on macOS 27.0.1, 2026-10-23, revealing and rehiding the hidden section quickly
/// wrote the preference 390–680 ms apart, and during the closest pair (390–430 ms) the whole
/// menu bar went black for about half a second, the Apple menu and the application menus with
/// it, and came back with items overlapping in mid-fade. MenuBarAgent lays the whole bar out
/// afresh when a write lands while it is still animating the last one.
///
/// So writes stand at least ``minimumSpacing`` apart. A request that arrives sooner is held,
/// replacing any request already held, and the last one is written once the spacing has passed:
/// one trailing write, however many requests came in between. A request for the state already
/// written drops whatever was held, since there is then nothing left to write.
///
/// Times are plain seconds on any monotonic clock, so the rule can be tested without one.
struct WritePacer27<Request: Equatable> {
    /// What the caller should do with a request.
    enum Decision: Equatable {
        /// Write it now.
        case writeNow

        /// Hold it; ``takeDue(at:)`` hands it back at the given time.
        case deferred(until: Double)

        /// Nothing to write: it is what was last written, and nothing is held any more.
        case dropped
    }

    /// The least time between two writes, in seconds.
    let minimumSpacing: Double

    /// When the preference was last actually written.
    private(set) var lastWriteAt: Double?

    /// The request last applied, whether or not it needed a write.
    private(set) var applied: Request?

    /// The request waiting for the spacing to pass.
    private(set) var pending: Request?

    init(minimumSpacing: Double) {
        self.minimumSpacing = minimumSpacing
    }

    /// When the next write may happen, or `nil` if it may happen now.
    func nextWriteAllowed(at now: Double) -> Double? {
        guard let lastWriteAt, now - lastWriteAt < minimumSpacing else {
            return nil
        }
        return lastWriteAt + minimumSpacing
    }

    /// Decides what to do with a request made at the given time.
    ///
    /// Outside the spacing a request is always written, even one equal to the last: the caller
    /// skips a write that would change nothing, and applying again is how it notices changes
    /// made by others, such as an application MenuBarAgent has only now started tracking.
    mutating func request(_ request: Request, at now: Double) -> Decision {
        guard let until = nextWriteAllowed(at: now) else {
            pending = nil
            return .writeNow
        }
        guard request != applied else {
            pending = nil
            return .dropped
        }
        pending = request
        return .deferred(until: until)
    }

    /// Hands back the held request once the spacing has passed, and forgets it.
    mutating func takeDue(at now: Double) -> Request? {
        guard pending != nil, nextWriteAllowed(at: now) == nil else {
            return nil
        }
        defer { pending = nil }
        return pending
    }

    /// Notes that a request was applied, and whether that took a write.
    ///
    /// Only a write starts the spacing: one that changed nothing set nothing moving.
    mutating func didApply(_ request: Request, wrote: Bool, at now: Double) {
        applied = request
        if wrote {
            lastWriteAt = now
        }
    }

    /// Forgets everything, as when the preference is handed back or another method takes over.
    mutating func reset() {
        lastWriteAt = nil
        applied = nil
        pending = nil
    }
}
