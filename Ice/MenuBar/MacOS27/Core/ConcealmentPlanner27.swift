//
//  ConcealmentPlanner27.swift
//  Ice
//

import Foundation

/// How much of Ice's hidden content is currently revealed.
enum RevealState27: Equatable {
    case allHidden
    case hiddenRevealed
    case allRevealed
}

/// Turns a layout and a reveal state into assessment-mode assertions.
///
/// Measured on macOS 27.0: live assertions combine as a union of their
/// allowlists, so an item shows if any assertion allows it. One assertion per
/// state is therefore enough, and a state that conceals nothing needs none —
/// which matters, because any live assertion also stops clicks on the clock.
enum ConcealmentPlanner27 {
    /// The concealed bundle sets, one per assertion, that produce the given state.
    static func concealedSets(layout: [String: MacOS27Section], state: RevealState27) -> [Set<String>] {
        switch state {
        case .allHidden:
            let concealed = SectionLayout27.bundles(in: [.hidden, .alwaysHidden], layout: layout)
            return concealed.isEmpty ? [] : [concealed]
        case .hiddenRevealed:
            let concealed = SectionLayout27.bundles(in: [.alwaysHidden], layout: layout)
            return concealed.isEmpty ? [] : [concealed]
        case .allRevealed:
            return []
        }
    }

    /// The allowlist an assertion needs to conceal exactly the given applications.
    static func allowlist(concealing concealed: Set<String>, running: Set<String>) -> [String] {
        running.subtracting(concealed).sorted()
    }

    /// The applications concealed while all of the given sets are live.
    static func effectivelyConcealed(sets: [Set<String>]) -> Set<String> {
        guard let first = sets.first else {
            return []
        }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }
    }
}
