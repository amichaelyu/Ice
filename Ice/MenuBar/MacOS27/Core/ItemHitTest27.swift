//
//  ItemHitTest27.swift
//  Ice
//

import CoreGraphics
import Darwin

/// Decides whether the pointer rests on a menu bar item on macOS 27.
///
/// There are no item windows on macOS 27, so the test uses the Accessibility
/// frames Ice cached for the drawn items, plus the system items and the overflow
/// button. Accessibility reports frames only for the active menu bar, so on the
/// other display every spot counts as empty, as it did in earlier versions of Ice.
enum ItemHitTest27 {
    struct Item: Equatable {
        let frame: CGRect
        let ownerPID: pid_t
        let isOnScreen: Bool
    }

    static func isInsideItem(point: CGPoint, items: [Item], concealedPIDs: Set<pid_t>, systemFrames: [CGRect]) -> Bool {
        let isInsideDrawnItem = items.contains { item in
            item.isOnScreen && !concealedPIDs.contains(item.ownerPID) && item.frame.contains(point)
        }
        return isInsideDrawnItem || systemFrames.contains { $0.contains(point) }
    }
}
