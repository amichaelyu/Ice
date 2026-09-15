//
//  ItemClick27.swift
//  Ice
//

import CoreGraphics

/// Pure rules for clicking an item from the Ice Bar on macOS 27.
enum ItemClick27 {
    /// Whether the menu bar of the Ice Bar's display must be made active first: an
    /// item's menu opens on the display with the active menu bar (measured on macOS 27.0).
    static func needsMenuBarActivation(activeDisplayID: CGDirectDisplayID?, iceBarDisplayID: CGDirectDisplayID?) -> Bool {
        guard let iceBarDisplayID else {
            return false
        }
        return activeDisplayID != iceBarDisplayID
    }

    /// Whether a window that was not on screen before the click belongs to the item's process.
    static func interfaceIsOpen(windowOwners: [(number: Int, ownerPID: Int32)], ownerPID: Int32, baseline: Set<Int>) -> Bool {
        windowOwners.contains { $0.ownerPID == ownerPID && !baseline.contains($0.number) }
    }
}
