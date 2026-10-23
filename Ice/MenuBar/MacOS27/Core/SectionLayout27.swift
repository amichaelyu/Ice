//
//  SectionLayout27.swift
//  Ice
//

import Foundation

/// A section as the macOS 27 backend sees it, ordered from most to least visible.
enum MacOS27Section: Int, Codable, CaseIterable, Comparable {
    case visible = 0
    case hidden = 1
    case alwaysHidden = 2

    static func < (lhs: MacOS27Section, rhs: MacOS27Section) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Which section each application belongs to.
///
/// macOS 27 hides whole applications, not single items, so the layout is kept
/// per bundle identifier.
enum SectionLayout27 {
    /// Collapses per-item sections into one section per application.
    ///
    /// An application whose items sit in different sections takes its most
    /// visible section, so an item the user left visible is never hidden.
    static func appSections(items: [(bundleID: String, section: MacOS27Section)]) -> [String: MacOS27Section] {
        items.reduce(into: [:]) { result, item in
            result[item.bundleID] = min(result[item.bundleID] ?? item.section, item.section)
        }
    }

    /// The layout to act on for the running applications.
    ///
    /// What was observed now wins, the saved layout covers applications whose
    /// items could not be read, and an application seen for the first time is
    /// visible.
    static func effectiveLayout(
        observed: [String: MacOS27Section],
        saved: [String: MacOS27Section],
        running: Set<String>
    ) -> [String: MacOS27Section] {
        running.reduce(into: [:]) { result, bundleID in
            result[bundleID] = observed[bundleID] ?? saved[bundleID] ?? .visible
        }
    }

    /// The sections the applications held before macOS 27, from the positions AppKit saved.
    ///
    /// AppKit keeps every status item's place in its owner's preferences, as
    /// `NSStatusItem Preferred Position <autosave name>`: points from the right edge of the bar,
    /// larger further left. Ice's dividers are kept the same way, in Ice's own preferences (704
    /// and 732 on the Mac this was written on). Before macOS 27 an item left of the hidden
    /// divider was hidden, and left of the always-hidden one always hidden, so the positions say
    /// what the bar said — and they survive the upgrade, where the bar's order does not: macOS 27
    /// rearranges the bar itself, and the order read there put every application in Visible.
    ///
    /// An application with several items takes the most hidden section any of them would have:
    /// the item the user dragged behind a divider is the one that says what they wanted, while an
    /// item left where it first appeared says nothing. An application with no saved position is
    /// left out, so it stays visible like any application the layout has not seen.
    ///
    /// - Parameters:
    ///   - preferredPositions: The saved positions of each application's items, by bundle identifier.
    ///   - hiddenDivider: The saved position of the divider for the hidden section.
    ///   - alwaysHiddenDivider: The saved position of the divider for the always-hidden section,
    ///     if that section is enabled. One that is not left of the hidden divider is ignored.
    static func seededLayout(
        preferredPositions: [String: [CGFloat]],
        hiddenDivider: CGFloat,
        alwaysHiddenDivider: CGFloat?
    ) -> [String: MacOS27Section] {
        let alwaysHiddenDivider = alwaysHiddenDivider.flatMap { $0 > hiddenDivider ? $0 : nil }
        return preferredPositions.reduce(into: [:]) { result, entry in
            let sections = entry.value.map { position -> MacOS27Section in
                if let alwaysHiddenDivider, position > alwaysHiddenDivider {
                    return .alwaysHidden
                }
                return position > hiddenDivider ? .hidden : .visible
            }
            result[entry.key] = sections.max()
        }
    }

    /// The applications whose section is one of the given sections.
    static func bundles(in sections: Set<MacOS27Section>, layout: [String: MacOS27Section]) -> Set<String> {
        Set(layout.compactMap { sections.contains($0.value) ? $0.key : nil })
    }
}
