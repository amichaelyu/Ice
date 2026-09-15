//
//  OverflowDetection27.swift
//  Ice
//

import CoreGraphics

/// Recognises items folded into the system "<<" overflow on macOS 27.
enum OverflowDetection27 {
    /// Measured on macOS 27.0: an item in the overflow reports the chevron's
    /// position as its own, so its frame says nothing about where it sits.
    static func isInOverflow(itemFrame: CGRect, chevronFrame: CGRect?) -> Bool {
        guard let chevronFrame else {
            return false
        }
        return abs(itemFrame.minX - chevronFrame.minX) <= 2
    }
}
