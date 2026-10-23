//
//  ItemOrder27.swift
//  Ice
//

/// Where an item goes in MenuBarAgent's saved order on macOS 27.
///
/// MenuBarAgent keeps each item's place as a position in points from the right end of the bar,
/// larger further left, and lays the bar out again when one changes (measured on macOS 27.0.1,
/// 2026-10-23). Moving an item is giving it a position between its new neighbours.
enum ItemOrder27 {
    /// The key MenuBarAgent saves an application's item under.
    static func key(bundleID: String, title: String) -> String {
        "status:\(bundleID)::\(title)"
    }

    /// The position for an item placed between two neighbours, or `nil` with neither.
    ///
    /// - Parameters:
    ///   - left: The position of the nearest item that is to end up on its left.
    ///   - right: The position of the nearest item that is to end up on its right.
    static func position(left: Double?, right: Double?) -> Double? {
        switch (left, right) {
        case let (left?, right?): (left + right) / 2
        case let (left?, nil): max(left - 1, 0)
        case let (nil, right?): right + 1
        case (nil, nil): nil
        }
    }

    /// The position for an item placed between the given neighbours, nearest first on each
    /// side, using the first of each that has a saved position.
    static func position(
        leftNeighbours: [String],
        rightNeighbours: [String],
        in positions: [String: Double]
    ) -> Double? {
        position(
            left: leftNeighbours.lazy.compactMap { positions[$0] }.first,
            right: rightNeighbours.lazy.compactMap { positions[$0] }.first
        )
    }
}
