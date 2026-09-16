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
    /// Whether a system item's panel opened, judged by the windows on screen.
    ///
    /// Notification Center, Control Centre and the battery and Wi-Fi panels all appear as a
    /// tall window above the menu bar's level (measured on macOS 27.0: Control Centre opens
    /// "Control Center", layer 101, 656×964, about 177 ms after the press).
    static func panelOpened(before: Set<Int>, windows: [(number: Int, layer: Int, height: CGFloat)]) -> Bool {
        windows.contains { window in
            !before.contains(window.number) && window.layer >= 100 && window.height > 150
        }
    }

    static func interfaceIsOpen(windowOwners: [(number: Int, ownerPID: Int32)], ownerPID: Int32, baseline: Set<Int>) -> Bool {
        windowOwners.contains { $0.ownerPID == ownerPID && !baseline.contains($0.number) }
    }
}
