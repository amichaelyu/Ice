//
//  ItemImages27.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Pure rules for menu bar item images on macOS 27.
enum ItemImages27 {
    /// The pixel rectangle of an item inside a capture of its display's menu bar strip,
    /// or `nil` if the item is not on that strip. Frames are in global points with the
    /// origin at the top left, like the capture.
    static func cropRect(itemFrame: CGRect, stripFrame: CGRect, scale: CGFloat) -> CGRect? {
        let clipped = itemFrame.intersection(stripFrame)
        guard !clipped.isNull, clipped.width >= itemFrame.width * 0.9 else {
            return nil
        }
        return CGRect(
            x: ((clipped.minX - stripFrame.minX) * scale).rounded(.down),
            y: ((clipped.minY - stripFrame.minY) * scale).rounded(.down),
            width: (clipped.width * scale).rounded(.up),
            height: (clipped.height * scale).rounded(.up)
        )
    }

    /// A stable file name for an item's image, safe to use on disk.
    static func fileName(forTag tag: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tag.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx.png", hash)
    }
}

/// Decides when an application may be shown for a moment to photograph its item.
struct PhotoSchedule27 {
    static let minimumInterval: TimeInterval = 600

    private var lastAttempts = [String: TimeInterval]()

    func mayPhotograph(bundleID: String, now: TimeInterval) -> Bool {
        guard let last = lastAttempts[bundleID] else {
            return true
        }
        return now - last >= Self.minimumInterval
    }

    mutating func recordAttempt(bundleID: String, now: TimeInterval) {
        lastAttempts[bundleID] = now
    }
}
