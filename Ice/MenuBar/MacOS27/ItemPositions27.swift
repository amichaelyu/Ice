//
//  ItemPositions27.swift
//  Ice
//

import Foundation
import OSLog

/// Reorders items on macOS 27 through MenuBarAgent's own saved positions (see ``ItemOrder27``).
///
/// The positions live in the `com.apple.MenuBar` group container, so this needs Full Disk Access
/// like the native hiding method. Writing one moved the item on the bar within about three
/// seconds, with no synthetic drag (measured on macOS 27.0.1, 2026-10-23).
@available(macOS 27.0, *)
enum ItemPositions27 {
    private static let key = "TrailingItemPreferredPositions"
    private static let logger = Logger(category: "ItemPositions27")

    /// Moves an item between the given neighbours, nearest first on each side, returning
    /// whether a position was written.
    @discardableResult
    static func place(_ item: String, leftNeighbours: [String], rightNeighbours: [String]) -> Bool {
        guard
            var positions = GroupPreferences27.menuBar.value(forKey: key) as? [String: Double],
            let position = ItemOrder27.position(leftNeighbours: leftNeighbours, rightNeighbours: rightNeighbours, in: positions)
        else {
            return false
        }
        positions[item] = position
        guard GroupPreferences27.menuBar.set(positions, forKey: key) else {
            logger.error("Could not save the position of \(item, privacy: .public)")
            return false
        }
        logger.notice("Placed \(item, privacy: .public) at \(position, privacy: .public)")
        return true
    }
}
